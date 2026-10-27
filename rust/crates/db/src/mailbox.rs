//! 邮箱账单同步的本机状态：同步游标与已处理邮件。均不参与 CloudKit。

use crate::BillRepository;
use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::Row;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MailSyncState {
    pub account_address: String,
    pub cursor: Option<DateTime<Utc>>,
    /// 本轮扫描的起点；游标为空时从这里开始。
    pub synced_from: Option<DateTime<Utc>>,
    pub last_synced_at: Option<DateTime<Utc>>,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MailMessageStatus {
    Imported,
    NeedsReview,
    Skipped,
}

impl MailMessageStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Imported => "imported",
            Self::NeedsReview => "needs_review",
            Self::Skipped => "skipped",
        }
    }
}

#[derive(Debug, Clone)]
pub struct MailMessageRecord {
    pub id: String,
    pub received_at: DateTime<Utc>,
    pub status: MailMessageStatus,
    /// 仅 `NeedsReview` 保留，供用户稍后预览确认。
    pub raw_mime: Option<Vec<u8>>,
    pub period_label: Option<String>,
    pub imported_count: i64,
    pub pending_count: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingMailStatement {
    pub message_id: String,
    pub received_at: DateTime<Utc>,
    pub period_label: Option<String>,
    pub imported_count: i64,
    pub pending_count: i64,
}

impl BillRepository {
    pub async fn get_mail_sync_state(&self, profile_id: &str) -> Result<Option<MailSyncState>> {
        let row = sqlx::query(
            "SELECT account_address, cursor, synced_from, last_synced_at, last_error FROM mail_sync_state WHERE profile_id = ?1",
        )
        .bind(profile_id)
        .fetch_optional(self.pool())
        .await
        .context("failed to load mail sync state")?;
        row.map(|row| {
            Ok(MailSyncState {
                account_address: row.try_get("account_address")?,
                cursor: row.try_get("cursor")?,
                synced_from: row.try_get("synced_from")?,
                last_synced_at: row.try_get("last_synced_at")?,
                last_error: row.try_get("last_error")?,
            })
        })
        .transpose()
    }

    /// 记录当前连接的邮箱。换了另一个邮箱时清空游标与已处理记录，从回溯窗口重新开始。
    pub async fn connect_mail_account(&self, profile_id: &str, address: &str) -> Result<()> {
        let mut tx = self
            .pool()
            .begin()
            .await
            .context("failed to begin mail account transaction")?;
        let existing: Option<String> =
            sqlx::query_scalar("SELECT account_address FROM mail_sync_state WHERE profile_id = ?1")
                .bind(profile_id)
                .fetch_optional(&mut *tx)
                .await
                .context("failed to load mail account")?;
        if existing.as_deref() != Some(address) {
            sqlx::query("DELETE FROM mail_messages WHERE profile_id = ?1")
                .bind(profile_id)
                .execute(&mut *tx)
                .await
                .context("failed to reset mail messages")?;
            sqlx::query(
                r#"
                INSERT INTO mail_sync_state (profile_id, account_address)
                VALUES (?1, ?2)
                ON CONFLICT (profile_id) DO UPDATE SET
                    account_address = excluded.account_address,
                    cursor = NULL, synced_from = NULL, last_synced_at = NULL, last_error = NULL,
                    updated_at = CURRENT_TIMESTAMP
                "#,
            )
            .bind(profile_id)
            .bind(address)
            .execute(&mut *tx)
            .await
            .context("failed to save mail account")?;
        }
        tx.commit()
            .await
            .context("failed to commit mail account transaction")
    }

    pub async fn mail_message_known(&self, profile_id: &str, message_id: &str) -> Result<bool> {
        let found: Option<i64> =
            sqlx::query_scalar("SELECT 1 FROM mail_messages WHERE profile_id = ?1 AND id = ?2")
                .bind(profile_id)
                .bind(message_id)
                .fetch_optional(self.pool())
                .await
                .context("failed to look up mail message")?;
        Ok(found.is_some())
    }

    pub async fn record_mail_message(
        &self,
        profile_id: &str,
        message: MailMessageRecord,
    ) -> Result<()> {
        sqlx::query(
            r#"
            INSERT INTO mail_messages (
                id, profile_id, received_at, status, raw_mime, period_label,
                imported_count, pending_count
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT (profile_id, id) DO NOTHING
            "#,
        )
        .bind(&message.id)
        .bind(profile_id)
        .bind(message.received_at)
        .bind(message.status.as_str())
        .bind(message.raw_mime)
        .bind(message.period_label)
        .bind(message.imported_count)
        .bind(message.pending_count)
        .execute(self.pool())
        .await
        .context("failed to record mail message")?;
        Ok(())
    }

    /// 同步起点提前（用户调大了同步月数）：清空游标，从新起点重扫。
    pub async fn reset_mail_sync_window(
        &self,
        profile_id: &str,
        synced_from: DateTime<Utc>,
    ) -> Result<()> {
        sqlx::query(
            r#"
            UPDATE mail_sync_state
            SET cursor = NULL, synced_from = ?2, updated_at = CURRENT_TIMESTAMP
            WHERE profile_id = ?1
            "#,
        )
        .bind(profile_id)
        .bind(synced_from)
        .execute(self.pool())
        .await
        .context("failed to reset mail sync window")?;
        Ok(())
    }

    /// 一轮同步结束：推进游标（只到成功处理的最后一封），记录时间与错误。
    pub async fn finish_mail_sync(
        &self,
        profile_id: &str,
        cursor: Option<DateTime<Utc>>,
        synced_at: DateTime<Utc>,
        error: Option<&str>,
    ) -> Result<()> {
        sqlx::query(
            r#"
            UPDATE mail_sync_state
            SET cursor = COALESCE(?2, cursor), last_synced_at = ?3, last_error = ?4,
                updated_at = CURRENT_TIMESTAMP
            WHERE profile_id = ?1
            "#,
        )
        .bind(profile_id)
        .bind(cursor)
        .bind(synced_at)
        .bind(error)
        .execute(self.pool())
        .await
        .context("failed to finish mail sync")?;
        Ok(())
    }

    pub async fn list_pending_mail_statements(
        &self,
        profile_id: &str,
    ) -> Result<Vec<PendingMailStatement>> {
        let rows = sqlx::query(
            r#"
            SELECT id, received_at, period_label, imported_count, pending_count
            FROM mail_messages
            WHERE profile_id = ?1 AND status = 'needs_review'
            ORDER BY received_at
            "#,
        )
        .bind(profile_id)
        .fetch_all(self.pool())
        .await
        .context("failed to list pending mail statements")?;
        rows.into_iter()
            .map(|row| {
                Ok(PendingMailStatement {
                    message_id: row.try_get("id")?,
                    received_at: row.try_get("received_at")?,
                    period_label: row.try_get("period_label")?,
                    imported_count: row.try_get("imported_count")?,
                    pending_count: row.try_get("pending_count")?,
                })
            })
            .collect()
    }

    pub async fn pending_mail_raw_mime(
        &self,
        profile_id: &str,
        message_id: &str,
    ) -> Result<Option<Vec<u8>>> {
        let raw: Option<Option<Vec<u8>>> = sqlx::query_scalar(
            "SELECT raw_mime FROM mail_messages WHERE profile_id = ?1 AND id = ?2 AND status = 'needs_review'",
        )
        .bind(profile_id)
        .bind(message_id)
        .fetch_optional(self.pool())
        .await
        .context("failed to load pending mail statement")?;
        Ok(raw.flatten())
    }

    /// 用户在预览中确认或忽略后：标为已处理并清空原始邮件。
    pub async fn resolve_mail_message(&self, profile_id: &str, message_id: &str) -> Result<bool> {
        let result = sqlx::query(
            r#"
            UPDATE mail_messages
            SET status = 'imported', raw_mime = NULL, pending_count = 0,
                updated_at = CURRENT_TIMESTAMP
            WHERE profile_id = ?1 AND id = ?2 AND status = 'needs_review'
            "#,
        )
        .bind(profile_id)
        .bind(message_id)
        .execute(self.pool())
        .await
        .context("failed to resolve mail message")?;
        Ok(result.rows_affected() == 1)
    }

    /// 断开邮箱：删除同步状态与全部邮件记录（含待确认的原始邮件）。已入账记录不受影响。
    pub async fn delete_mail_sync(&self, profile_id: &str) -> Result<()> {
        let mut tx = self
            .pool()
            .begin()
            .await
            .context("failed to begin mail disconnect transaction")?;
        sqlx::query("DELETE FROM mail_messages WHERE profile_id = ?1")
            .bind(profile_id)
            .execute(&mut *tx)
            .await
            .context("failed to delete mail messages")?;
        sqlx::query("DELETE FROM mail_sync_state WHERE profile_id = ?1")
            .bind(profile_id)
            .execute(&mut *tx)
            .await
            .context("failed to delete mail sync state")?;
        tx.commit()
            .await
            .context("failed to commit mail disconnect transaction")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    async fn repo() -> BillRepository {
        let path = std::env::temp_dir().join(format!("billlens-mail-{}.sqlite", Uuid::new_v4()));
        BillRepository::connect(path).await.unwrap()
    }

    fn message(id: &str, status: MailMessageStatus) -> MailMessageRecord {
        MailMessageRecord {
            id: id.to_string(),
            received_at: Utc::now(),
            status,
            raw_mime: (status == MailMessageStatus::NeedsReview).then(|| b"raw".to_vec()),
            period_label: Some("2026/09/26–2026/10/25".into()),
            imported_count: 3,
            pending_count: 1,
        }
    }

    #[tokio::test]
    async fn switching_accounts_resets_cursor_and_messages_but_reconnecting_keeps_them() {
        let repo = repo().await;
        repo.connect_mail_account("p", "a@hotmail.com")
            .await
            .unwrap();
        repo.record_mail_message("p", message("m1", MailMessageStatus::Skipped))
            .await
            .unwrap();
        let now = Utc::now();
        repo.finish_mail_sync("p", Some(now), now, None)
            .await
            .unwrap();

        repo.connect_mail_account("p", "a@hotmail.com")
            .await
            .unwrap();
        assert!(repo.mail_message_known("p", "m1").await.unwrap());
        assert!(
            repo.get_mail_sync_state("p")
                .await
                .unwrap()
                .unwrap()
                .cursor
                .is_some()
        );

        repo.connect_mail_account("p", "b@hotmail.com")
            .await
            .unwrap();
        assert!(!repo.mail_message_known("p", "m1").await.unwrap());
        let state = repo.get_mail_sync_state("p").await.unwrap().unwrap();
        assert_eq!(state.account_address, "b@hotmail.com");
        assert_eq!(state.cursor, None);
    }

    #[tokio::test]
    async fn pending_statements_resolve_and_disconnect_clears_raw_mail() {
        let repo = repo().await;
        repo.connect_mail_account("p", "a@hotmail.com")
            .await
            .unwrap();
        repo.record_mail_message("p", message("m1", MailMessageStatus::NeedsReview))
            .await
            .unwrap();
        repo.record_mail_message("p", message("m2", MailMessageStatus::Imported))
            .await
            .unwrap();

        let pending = repo.list_pending_mail_statements("p").await.unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].message_id, "m1");
        assert_eq!(
            repo.pending_mail_raw_mime("p", "m1").await.unwrap(),
            Some(b"raw".to_vec())
        );
        assert_eq!(repo.pending_mail_raw_mime("p", "m2").await.unwrap(), None);

        assert!(repo.resolve_mail_message("p", "m1").await.unwrap());
        assert!(!repo.resolve_mail_message("p", "m1").await.unwrap());
        assert!(
            repo.list_pending_mail_statements("p")
                .await
                .unwrap()
                .is_empty()
        );
        let raw: Option<Vec<u8>> =
            sqlx::query_scalar("SELECT raw_mime FROM mail_messages WHERE id = 'm1'")
                .fetch_one(repo.pool())
                .await
                .unwrap();
        assert_eq!(raw, None);

        repo.delete_mail_sync("p").await.unwrap();
        assert!(repo.get_mail_sync_state("p").await.unwrap().is_none());
        assert!(!repo.mail_message_known("p", "m2").await.unwrap());
    }

    #[tokio::test]
    async fn cursor_only_moves_forward_when_provided() {
        let repo = repo().await;
        repo.connect_mail_account("p", "a@hotmail.com")
            .await
            .unwrap();
        let first = Utc::now();
        repo.finish_mail_sync("p", Some(first), first, None)
            .await
            .unwrap();
        repo.finish_mail_sync("p", None, Utc::now(), Some("network"))
            .await
            .unwrap();
        let state = repo.get_mail_sync_state("p").await.unwrap().unwrap();
        assert_eq!(state.cursor, Some(first));
        assert_eq!(state.last_error.as_deref(), Some("network"));
    }

    #[tokio::test]
    async fn resetting_window_clears_cursor_and_keeps_messages() {
        let repo = repo().await;
        repo.connect_mail_account("p", "a@hotmail.com")
            .await
            .unwrap();
        let now = Utc::now();
        repo.finish_mail_sync("p", Some(now), now, None)
            .await
            .unwrap();
        let from = now - chrono::Duration::days(365);
        repo.reset_mail_sync_window("p", from).await.unwrap();
        let state = repo.get_mail_sync_state("p").await.unwrap().unwrap();
        assert_eq!(state.cursor, None);
        assert_eq!(state.synced_from, Some(from));
    }
}
