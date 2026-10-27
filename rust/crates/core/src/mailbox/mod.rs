//! 邮箱账单同步：从 Hotmail（Microsoft Graph）或 iCloud（IMAP）拉取招行账单邮件，复用账单导入链路自动入账。
//!
//! - 勾稽全部通过：默认勾选且状态为 New 的行自动入账；疑似重复、「其他」分区留待确认。
//! - 勾稽失败或没有汇总：整封留待确认，不自动入账。
//! - 非账单邮件（解析失败）记为已跳过。
//!
//! 每封邮件按来源内的 ID 只处理一次；记录 ID 是确定性的，重复处理也不会重复入账。

pub mod graph;
pub mod imap;
pub mod source;

use crate::statement::{
    StatementLineStatus, StatementSourceInput, StatementSourceKind, build_lines, decode_statement,
    period_label, reconcile, record_create,
};
use crate::{AppService, CoreError, HomeSnapshot, logger, map_internal};
use base64::Engine;
use billlens_apple_db::{
    MailMessageRecord, MailMessageStatus, MailSyncState, PendingMailStatement,
};
use chrono::{DateTime, Months, Utc};
use graph::{GRAPH_BASE_URL, GraphClient, GraphSource};
use imap::ImapSource;
use serde::{Deserialize, Serialize};
use source::{MailRef, MailSource, MailboxError};

/// 默认同步最近几个月的账单邮件。
pub const DEFAULT_LOOKBACK_MONTHS: u32 = 3;
/// 可选的最长同步月数。
pub const MAX_LOOKBACK_MONTHS: u32 = 24;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MailboxSyncResult {
    /// 本轮自动入账的笔数。
    pub imported: usize,
    /// 本轮新增的待确认账单封数。
    pub new_pending_statements: usize,
    pub skipped: usize,
    /// 本轮从邮箱列出的招行邮件封数（含已处理过的），用于提示「没找到账单邮件」。
    pub scanned: usize,
    /// 令牌失效或授权被撤销：Swift 应清除令牌并提示重新连接。
    pub needs_reauth: bool,
    /// 本轮未完成（网络 / 限流 / 服务端错误）的原因，进度已保存，下次继续。
    pub error: Option<String>,
    pub state: Option<MailSyncState>,
    pub pending: Vec<PendingMailStatement>,
    pub home: HomeSnapshot,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MailboxStatus {
    pub state: Option<MailSyncState>,
    pub pending: Vec<PendingMailStatement>,
}

enum Outcome {
    Imported {
        count: usize,
    },
    NeedsReview {
        imported: usize,
        pending: usize,
        period: String,
    },
    Skipped,
}

impl AppService {
    /// Hotmail：Swift 刷新后的 access token。
    pub async fn sync_mailbox(
        &self,
        profile_id: &str,
        access_token: &str,
        account_address: &str,
        lookback_months: u32,
    ) -> Result<MailboxSyncResult, CoreError> {
        if access_token.trim().is_empty() {
            return Err(CoreError::bad_request("授权令牌不能为空"));
        }
        let client = GraphClient::new(GRAPH_BASE_URL);
        let mut source = GraphSource {
            client: &client,
            access_token,
        };
        self.sync_mailbox_with(&mut source, profile_id, account_address, lookback_months)
            .await
    }

    /// iCloud：邮箱地址 + App 专用密码，经 IMAP 读取收件箱。
    pub async fn sync_icloud_mailbox(
        &self,
        profile_id: &str,
        account_address: &str,
        password: &str,
        lookback_months: u32,
    ) -> Result<MailboxSyncResult, CoreError> {
        if password.trim().is_empty() {
            return Err(CoreError::bad_request("App 专用密码不能为空"));
        }
        let mut source = ImapSource::icloud(account_address, password);
        let result = self
            .sync_mailbox_with(&mut source, profile_id, account_address, lookback_months)
            .await;
        source.logout().await;
        result
    }

    /// 连接 iCloud 前校验地址与 App 专用密码。
    pub async fn verify_icloud_mailbox(
        &self,
        account_address: &str,
        password: &str,
    ) -> Result<(), CoreError> {
        if account_address.trim().is_empty() || password.trim().is_empty() {
            return Err(CoreError::bad_request(
                "请填写 iCloud 邮箱地址和 App 专用密码",
            ));
        }
        let mut source = ImapSource::icloud(account_address, password);
        let result = source.verify().await;
        source.logout().await;
        logger::info(
            "mailbox.verify",
            format!(
                "result={}",
                result
                    .as_ref()
                    .err()
                    .map(MailboxError::kind)
                    .unwrap_or("ok")
            ),
        );
        match result {
            Ok(()) => Ok(()),
            Err(MailboxError::Unauthorized) => Err(CoreError::bad_request(
                "iCloud 邮箱登录失败：请确认邮箱地址，并使用 App 专用密码（不是 Apple 账户密码）",
            )),
            Err(error) => Err(CoreError::bad_request(error.to_string())),
        }
    }

    pub(crate) async fn sync_mailbox_with(
        &self,
        source: &mut impl MailSource,
        profile_id: &str,
        account_address: &str,
        lookback_months: u32,
    ) -> Result<MailboxSyncResult, CoreError> {
        let address = account_address.trim();
        if address.is_empty() {
            return Err(CoreError::bad_request("邮箱地址不能为空"));
        }
        if !(1..=MAX_LOOKBACK_MONTHS).contains(&lookback_months) {
            return Err(CoreError::bad_request(format!(
                "同步月数需在 1 到 {MAX_LOOKBACK_MONTHS} 之间"
            )));
        }
        let _guard = self.mail_sync_lock.lock().await;
        self.repo
            .connect_mail_account(profile_id, address)
            .await
            .map_err(map_internal)?;
        let state = self
            .repo
            .get_mail_sync_state(profile_id)
            .await
            .map_err(map_internal)?;
        let started_at = Utc::now();
        let window_start = started_at
            .checked_sub_months(Months::new(lookback_months))
            .ok_or_else(|| CoreError::bad_request("同步月数无效"))?;
        // 起点只在首次或用户调大月数时重置；调小月数不影响已入账的记录，也不重扫。
        let since = match state.and_then(|state| state.synced_from.map(|from| (from, state.cursor)))
        {
            Some((from, cursor)) if from <= window_start => cursor.unwrap_or(from),
            _ => {
                self.repo
                    .reset_mail_sync_window(profile_id, window_start)
                    .await
                    .map_err(map_internal)?;
                window_start
            }
        };

        let mut imported = 0;
        let mut new_pending = 0;
        let mut skipped = 0;
        let mut scanned = 0;
        let mut cursor: Option<DateTime<Utc>> = None;
        let failure = match source.list_statement_messages(since).await {
            Err(error) => Some(error),
            Ok(messages) => {
                scanned = messages.len();
                let mut failure = None;
                for message in messages {
                    match self.process_message(source, profile_id, &message).await {
                        Ok(Some(Outcome::Imported { count })) => imported += count,
                        Ok(Some(Outcome::NeedsReview {
                            imported: count, ..
                        })) => {
                            imported += count;
                            new_pending += 1;
                        }
                        Ok(Some(Outcome::Skipped)) => skipped += 1,
                        Ok(None) => {}
                        Err(error) => {
                            // 游标停在出错前一封，下次从这里继续；已处理的邮件不会重复处理。
                            failure = Some(error);
                            break;
                        }
                    }
                    cursor = Some(message.received_at);
                }
                failure
            }
        };

        let error_text = failure.as_ref().map(ToString::to_string);
        self.repo
            .finish_mail_sync(profile_id, cursor, started_at, error_text.as_deref())
            .await
            .map_err(map_internal)?;
        logger::info(
            "mailbox.sync",
            format!(
                "imported={imported} new_pending={new_pending} skipped={skipped} scanned={scanned} error={}",
                failure.as_ref().map(MailboxError::kind).unwrap_or("none")
            ),
        );
        let status = self.mailbox_status(profile_id).await?;
        Ok(MailboxSyncResult {
            imported,
            new_pending_statements: new_pending,
            skipped,
            scanned,
            needs_reauth: failure == Some(MailboxError::Unauthorized),
            error: error_text,
            state: status.state,
            pending: status.pending,
            home: self.home(profile_id).await.map_err(map_internal)?,
        })
    }

    /// 返回 `Ok(None)` 表示此前已处理过。下载失败返回 `Err`，由调用方停止本轮。
    async fn process_message(
        &self,
        source: &mut impl MailSource,
        profile_id: &str,
        message: &MailRef,
    ) -> Result<Option<Outcome>, MailboxError> {
        let known = self
            .repo
            .mail_message_known(profile_id, &message.id)
            .await
            .map_err(|error| MailboxError::Decode(format!("{error:#}")))?;
        if known {
            return Ok(None);
        }
        let mime = source.message_mime(&message.id).await?;
        let outcome = self
            .import_statement_mail(profile_id, &mime)
            .await
            .map_err(|error| MailboxError::Decode(error.to_string()))?;
        let (status, raw_mime, period, imported, pending) = match &outcome {
            Outcome::Imported { count } => (MailMessageStatus::Imported, None, None, *count, 0),
            Outcome::NeedsReview {
                imported,
                pending,
                period,
            } => (
                MailMessageStatus::NeedsReview,
                Some(mime),
                Some(period.clone()),
                *imported,
                *pending,
            ),
            Outcome::Skipped => (MailMessageStatus::Skipped, None, None, 0, 0),
        };
        self.repo
            .record_mail_message(
                profile_id,
                MailMessageRecord {
                    id: message.id.clone(),
                    received_at: message.received_at,
                    status,
                    raw_mime,
                    period_label: period,
                    imported_count: imported as i64,
                    pending_count: pending as i64,
                },
            )
            .await
            .map_err(|error| MailboxError::Decode(format!("{error:#}")))?;
        Ok(Some(outcome))
    }

    async fn import_statement_mail(
        &self,
        profile_id: &str,
        mime: &[u8],
    ) -> Result<Outcome, CoreError> {
        let source = StatementSourceInput {
            kind: StatementSourceKind::Eml,
            content: base64::engine::general_purpose::STANDARD.encode(mime),
        };
        // 非账单邮件（如还款提醒）解析失败属于正常情况，记为跳过。
        let Ok(parsed) = decode_statement(&source) else {
            return Ok(Outcome::Skipped);
        };
        let time_zone = self.time_zone();
        // 内容层面无法生成明细（如日期无法换算）是确定性的：重试也不会成功，记为跳过，
        // 避免一封异常邮件让游标永远卡住。数据库等内部错误仍停止本轮。
        let mut lines = match build_lines(profile_id, &parsed, time_zone) {
            Ok(lines) => lines,
            Err(CoreError::BadRequest(_)) => {
                logger::info("mailbox.sync", "statement lines rejected; skipped");
                return Ok(Outcome::Skipped);
            }
            Err(error) => return Err(error),
        };
        self.mark_existing_and_duplicates(profile_id, &mut lines, time_zone)
            .await
            .map_err(map_internal)?;

        let checks = reconcile(&parsed);
        let reconciled = !checks.is_empty() && checks.iter().all(|check| check.ok);
        let auto: Vec<_> = if reconciled {
            lines
                .iter()
                .filter(|line| line.default_selected && line.status == StatementLineStatus::New)
                .filter_map(|line| {
                    line.direction.clone().map(|direction| {
                        (
                            line.line_id,
                            record_create(line, direction, line.category.clone()),
                        )
                    })
                })
                .collect()
        } else {
            Vec::new()
        };
        let auto_ids: std::collections::HashSet<_> = auto.iter().map(|(id, _)| *id).collect();
        let pending = lines
            .iter()
            .filter(|line| {
                line.direction.is_some()
                    && line.status != StatementLineStatus::Imported
                    && !auto_ids.contains(&line.line_id)
            })
            .count();

        let imported = if auto.is_empty() {
            0
        } else {
            self.import_lines(profile_id, &parsed, auto, "已从邮箱自动导入")
                .await?
                .inserted
        };
        Ok(if pending > 0 {
            Outcome::NeedsReview {
                imported,
                pending,
                period: period_label(&parsed),
            }
        } else {
            Outcome::Imported { count: imported }
        })
    }

    pub async fn mailbox_status(&self, profile_id: &str) -> Result<MailboxStatus, CoreError> {
        Ok(MailboxStatus {
            state: self
                .repo
                .get_mail_sync_state(profile_id)
                .await
                .map_err(map_internal)?,
            pending: self
                .repo
                .list_pending_mail_statements(profile_id)
                .await
                .map_err(map_internal)?,
        })
    }

    /// 待确认账单的原始邮件，交给已有的导入预览 / 确认流程。
    pub async fn mail_statement_source(
        &self,
        profile_id: &str,
        message_id: &str,
    ) -> Result<StatementSourceInput, CoreError> {
        let raw = self
            .repo
            .pending_mail_raw_mime(profile_id, message_id)
            .await
            .map_err(map_internal)?
            .ok_or_else(|| CoreError::bad_request("这封账单已处理或不存在"))?;
        Ok(StatementSourceInput {
            kind: StatementSourceKind::Eml,
            content: base64::engine::general_purpose::STANDARD.encode(raw),
        })
    }

    /// 预览中确认或忽略后调用：清空原始邮件，不再提示。
    pub async fn resolve_mail_statement(
        &self,
        profile_id: &str,
        message_id: &str,
    ) -> Result<MailboxStatus, CoreError> {
        self.repo
            .resolve_mail_message(profile_id, message_id)
            .await
            .map_err(map_internal)?;
        self.mailbox_status(profile_id).await
    }

    pub async fn disconnect_mailbox(&self, profile_id: &str) -> Result<(), CoreError> {
        let _guard = self.mail_sync_lock.lock().await;
        self.repo
            .delete_mail_sync(profile_id)
            .await
            .map_err(map_internal)?;
        logger::info("mailbox.disconnect", "cleared");
        Ok(())
    }
}

#[cfg(test)]
mod tests;
