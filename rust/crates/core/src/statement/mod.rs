//! 信用卡电子账单导入：解析预览（不写库）与按确定性 ID 的原子确认。
//!
//! 记录 ID 为 UUID v5，key 只含尾号、分区、日期、金额与同 key 序号，不含摘要文字：
//! 同一封账单从 `.eml` 或 iOS 打印 PDF 导入、在哪台设备导入，都得到同一组 ID。

mod classify;
mod cmb;
mod source;

pub use cmb::StatementSection;
pub use source::{StatementSourceInput, StatementSourceKind};

use crate::{
    AppService, CoreError, HomeSnapshot, RecordCreate, RecordDirection, RecordsStatsRange,
    STATS_CURRENCY, is_valid_record_category_for_direction, logger, map_internal,
};
use billlens_apple_db::StatementImportCounts;
use chrono::{DateTime, Duration, NaiveDate, TimeZone, Utc};
use chrono_tz::Tz;
use cmb::CmbRow;
pub(crate) use cmb::CmbStatement;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use uuid::Uuid;

const BANK_NAME: &str = "招商银行信用卡";
/// 账单行记录 ID 的 UUID v5 命名空间。已发布后不得修改，否则重复导入会产生新记录。
const STATEMENT_NAMESPACE: Uuid = Uuid::from_u128(0x6b1f_93c2_7d0e_4c55_9a3e_51d8_0f2c_b7a4);
/// 与手动记录比对疑似重复时允许的日期差。
const DUPLICATE_WINDOW_DAYS: i64 = 2;
/// 账单只有日期，入账时刻统一取设备时区当天中午。
const STATEMENT_HOUR: u32 = 12;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StatementLineStatus {
    New,
    Imported,
    SuspectedDuplicate,
    Excluded,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatementLine {
    pub line_id: Uuid,
    pub section: StatementSection,
    /// None 表示不入账（还款、取现本金）。
    pub direction: Option<RecordDirection>,
    pub amount: f64,
    pub transaction_at: DateTime<Utc>,
    pub description: String,
    pub merchant: String,
    pub card_last4: String,
    pub category: String,
    pub note: String,
    pub status: StatementLineStatus,
    pub matched_record: Option<StatementMatchedRecord>,
    pub default_selected: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatementMatchedRecord {
    pub id: Uuid,
    pub merchant: Option<String>,
    pub category: String,
    pub transaction_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReconciliationCheck {
    pub name: String,
    pub expected: f64,
    pub actual: f64,
    pub ok: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatementPreview {
    pub bank: String,
    pub card_last4: Vec<String>,
    pub period_start: NaiveDate,
    pub period_end: NaiveDate,
    pub due_on: Option<NaiveDate>,
    pub amount_due: Option<f64>,
    pub reconciliation: Vec<ReconciliationCheck>,
    pub lines: Vec<StatementLine>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatementImportResult {
    pub inserted: usize,
    pub skipped_existing: usize,
    pub home: HomeSnapshot,
}

impl AppService {
    pub async fn parse_statement(
        &self,
        profile_id: &str,
        source: &StatementSourceInput,
    ) -> Result<StatementPreview, CoreError> {
        let time_zone = self.time_zone();
        let statement = decode_statement(source)?;
        let mut lines = build_lines(profile_id, &statement, time_zone)?;
        self.mark_existing_and_duplicates(profile_id, &mut lines, time_zone)
            .await
            .map_err(map_internal)?;
        let preview = build_preview(statement, lines);
        let count = |status| preview.lines.iter().filter(|l| l.status == status).count();
        logger::info(
            "statement.parse",
            format!(
                "source={:?} lines={} new={} imported={} duplicates={} excluded={} reconciled={}",
                source.kind,
                preview.lines.len(),
                count(StatementLineStatus::New),
                count(StatementLineStatus::Imported),
                count(StatementLineStatus::SuspectedDuplicate),
                count(StatementLineStatus::Excluded),
                preview.reconciliation.iter().all(|check| check.ok),
            ),
        );
        Ok(preview)
    }

    /// 重新解析同一份来源，只接受其中可入账的行 ID，不信任客户端回传的金额与日期。
    pub async fn confirm_statement_import(
        &self,
        profile_id: &str,
        source: &StatementSourceInput,
        selected_line_ids: &[Uuid],
        category_overrides: &HashMap<Uuid, String>,
    ) -> Result<StatementImportResult, CoreError> {
        if selected_line_ids.is_empty() {
            return Err(CoreError::bad_request("请至少选择一笔账单"));
        }
        let time_zone = self.time_zone();
        let statement = decode_statement(source)?;
        let lines = build_lines(profile_id, &statement, time_zone)?;
        let by_id: HashMap<Uuid, &StatementLine> = lines.iter().map(|l| (l.line_id, l)).collect();

        let mut seen = HashSet::new();
        let mut records = Vec::with_capacity(selected_line_ids.len());
        for id in selected_line_ids {
            if !seen.insert(*id) {
                return Err(CoreError::bad_request(format!("重复的账单行 {id}")));
            }
            let line = by_id
                .get(id)
                .ok_or_else(|| CoreError::bad_request(format!("账单中不存在该行 {id}")))?;
            let direction = line
                .direction
                .clone()
                .ok_or_else(|| CoreError::bad_request("还款、取现本金不能导入为账单"))?;
            let category = category_overrides.get(id).unwrap_or(&line.category).clone();
            if !is_valid_record_category_for_direction(Some(&direction), &category) {
                return Err(CoreError::bad_request(format!("无效的分类：{category}")));
            }
            records.push((*id, record_create(line, direction, category)));
        }
        if let Some(unknown) = category_overrides.keys().find(|id| !seen.contains(id)) {
            return Err(CoreError::bad_request(format!(
                "分类修改指向未选择的账单行 {unknown}"
            )));
        }

        let counts = self
            .import_lines(profile_id, &statement, records, "已导入")
            .await?;
        logger::info(
            "statement.confirm",
            format!(
                "inserted={} skipped_existing={}",
                counts.inserted, counts.skipped_existing
            ),
        );
        Ok(StatementImportResult {
            inserted: counts.inserted,
            skipped_existing: counts.skipped_existing,
            home: self.home(profile_id).await.map_err(map_internal)?,
        })
    }

    /// 单事务写入账单行与一条助手消息；手动确认与邮箱自动导入共用。
    pub(crate) async fn import_lines(
        &self,
        profile_id: &str,
        statement: &CmbStatement,
        records: Vec<(Uuid, RecordCreate)>,
        verb: &str,
    ) -> Result<StatementImportCounts, CoreError> {
        let card = card_label(&statement.rows);
        let period = period_label(statement);
        self.repo
            .import_statement_records(profile_id, &self.device_id, records, |inserted, skipped| {
                let mut message = format!("{verb}{BANK_NAME}（{card}）{period} 账单 {inserted} 笔");
                if skipped > 0 {
                    message.push_str(&format!("，跳过已存在的 {skipped} 笔"));
                }
                message.push('。');
                message
            })
            .await
            .map_err(map_internal)
    }

    pub(crate) async fn mark_existing_and_duplicates(
        &self,
        profile_id: &str,
        lines: &mut [StatementLine],
        time_zone: Tz,
    ) -> anyhow::Result<()> {
        let ids: Vec<Uuid> = lines.iter().map(|line| line.line_id).collect();
        let existing: HashSet<Uuid> = self
            .repo
            .find_existing_record_ids(&ids)
            .await?
            .into_iter()
            .collect();
        for line in lines.iter_mut() {
            if line.direction.is_some() && existing.contains(&line.line_id) {
                line.status = StatementLineStatus::Imported;
                line.default_selected = false;
            }
        }

        let candidates: Vec<usize> = (0..lines.len())
            .filter(|&i| lines[i].status == StatementLineStatus::New)
            .collect();
        let (Some(start), Some(end)) = (
            candidates.iter().map(|&i| lines[i].transaction_at).min(),
            candidates.iter().map(|&i| lines[i].transaction_at).max(),
        ) else {
            return Ok(());
        };
        let window = Duration::days(DUPLICATE_WINDOW_DAYS + 1);
        let statement_ids: HashSet<Uuid> = ids.into_iter().collect();
        let records: Vec<_> = self
            .repo
            .list_records(
                profile_id,
                &RecordsStatsRange {
                    start_at: start - window,
                    end_at: end + window,
                },
                None,
                None,
            )
            .await?
            .into_iter()
            .filter(|r| !statement_ids.contains(&r.id) && r.currency == STATS_CURRENCY)
            .collect();

        // 一条手动记录最多标记一行账单，按日期差最小贪心匹配。
        let mut used = HashSet::new();
        for i in candidates {
            let line = &lines[i];
            let line_day = local_day(line.transaction_at, time_zone);
            let best = records
                .iter()
                .filter(|r| !used.contains(&r.id))
                .filter(|r| Some(&r.direction) == line.direction.as_ref())
                .filter(|r| to_cents(r.amount) == to_cents(line.amount))
                .map(|r| {
                    (
                        r,
                        (local_day(r.transaction_at, time_zone) - line_day)
                            .num_days()
                            .abs(),
                    )
                })
                .filter(|(_, diff)| *diff <= DUPLICATE_WINDOW_DAYS)
                .min_by_key(|(_, diff)| *diff)
                .map(|(r, _)| r);
            if let Some(record) = best {
                used.insert(record.id);
                let line = &mut lines[i];
                line.status = StatementLineStatus::SuspectedDuplicate;
                line.default_selected = false;
                line.matched_record = Some(StatementMatchedRecord {
                    id: record.id,
                    merchant: record.merchant.clone(),
                    category: record.category.clone(),
                    transaction_at: record.transaction_at,
                });
            }
        }
        Ok(())
    }
}

pub(crate) fn decode_statement(source: &StatementSourceInput) -> Result<CmbStatement, CoreError> {
    let decoded = source::decode(source).map_err(|e| CoreError::bad_request(format!("{e:#}")))?;
    let is_cmb_sender = decoded
        .sender
        .as_deref()
        .is_some_and(|sender| sender.to_ascii_lowercase().ends_with("cmbchina.com"));
    let is_cmb_subject = decoded
        .subject
        .as_deref()
        .is_some_and(|subject| subject.contains(BANK_NAME));
    let mentions_cmb = decoded.lines.iter().any(|line| line.contains("招商银行"));
    if !(is_cmb_sender || is_cmb_subject || mentions_cmb) {
        return Err(CoreError::bad_request(
            "这不是招商银行信用卡电子账单，目前仅支持招商银行信用卡",
        ));
    }
    cmb::parse(&decoded.lines).map_err(|e| CoreError::bad_request(format!("{e:#}")))
}

pub(crate) fn build_lines(
    profile_id: &str,
    statement: &CmbStatement,
    time_zone: Tz,
) -> Result<Vec<StatementLine>, CoreError> {
    let mut occurrences: HashMap<String, usize> = HashMap::new();
    statement
        .rows
        .iter()
        .map(|row| {
            let key = fingerprint_key(profile_id, row);
            let seq = occurrences.entry(key.clone()).or_default();
            let line_id = Uuid::new_v5(&STATEMENT_NAMESPACE, format!("{key}|{seq}").as_bytes());
            *seq += 1;
            build_line(line_id, row, time_zone)
        })
        .collect()
}

fn fingerprint_key(profile_id: &str, row: &CmbRow) -> String {
    format!(
        "cmb|{profile_id}|{}|{}|{}|{}|{}",
        row.card_last4,
        row.section.as_str(),
        row.posted_on,
        row.transaction_on
            .map(|d| d.to_string())
            .unwrap_or_default(),
        row.amount_cents,
    )
}

fn build_line(line_id: Uuid, row: &CmbRow, time_zone: Tz) -> Result<StatementLine, CoreError> {
    use StatementSection::*;
    let split = classify::split_description(&row.description);
    let direction = match row.section {
        Repayment | Cash => None,
        _ if row.amount_cents < 0 => Some(RecordDirection::Income),
        _ => Some(RecordDirection::Expense),
    };
    let category = match &direction {
        None => String::new(),
        Some(RecordDirection::Income) => "退款".to_string(),
        Some(RecordDirection::Expense) => match row.section {
            Fee | Interest => "其他".to_string(),
            _ => classify::expense_category(&row.description, split.channel).to_string(),
        },
    };
    let date = match row.section {
        Purchase | Refund | Other => row.transaction_on.unwrap_or(row.posted_on),
        Installment | Fee | Interest | Repayment | Cash => row.posted_on,
    };
    let transaction_at = time_zone
        .from_local_datetime(&date.and_hms_opt(STATEMENT_HOUR, 0, 0).expect("valid noon"))
        .earliest()
        .ok_or_else(|| CoreError::bad_request(format!("无法换算账单日期 {date}")))?
        .with_timezone(&Utc);

    let mut note = format!("招行信用卡 尾号{}", row.card_last4);
    if let Some(channel) = split.channel {
        note.push_str(&format!(" · {channel}"));
    }
    if let Some(detail) = &split.detail {
        note.push_str(&format!(" · 分期 {detail}"));
    }
    if let Some(location) = row.location.as_deref().filter(|l| *l != "CN") {
        note.push_str(&format!(
            " · 交易地 {location} 金额 {}",
            format_cents(row.settlement_cents)
        ));
    }

    let status = if direction.is_some() {
        StatementLineStatus::New
    } else {
        StatementLineStatus::Excluded
    };
    let default_selected = direction.is_some() && row.section != Other;
    Ok(StatementLine {
        line_id,
        section: row.section.clone(),
        direction,
        amount: row.amount_cents.unsigned_abs() as f64 / 100.0,
        transaction_at,
        description: row.description.clone(),
        merchant: split.merchant,
        card_last4: row.card_last4.clone(),
        category,
        note,
        status,
        matched_record: None,
        default_selected,
    })
}

fn build_preview(statement: CmbStatement, lines: Vec<StatementLine>) -> StatementPreview {
    let card_last4: Vec<String> = statement
        .rows
        .iter()
        .map(|row| row.card_last4.clone())
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect();
    StatementPreview {
        bank: BANK_NAME.to_string(),
        card_last4,
        period_start: statement.period_start,
        period_end: statement.period_end,
        due_on: statement.due_on,
        amount_due: statement.summary.map(|s| s.amount_due as f64 / 100.0),
        reconciliation: reconcile(&statement),
        lines,
    }
}

/// 勾稽：本期新增 = 消费 + 分期 + 取现 + 费用；本期调整 = −退款；循环利息 = 利息；
/// 本期应还 = 上期账单 + 还款 + 新增 − 调整 + 利息。「其他」分区不参与，差额会暴露出来。
pub(crate) fn reconcile(statement: &CmbStatement) -> Vec<ReconciliationCheck> {
    use StatementSection::*;
    let Some(summary) = statement.summary else {
        return Vec::new();
    };
    let mut sums: BTreeMap<&'static str, i64> = BTreeMap::new();
    for row in &statement.rows {
        *sums.entry(row.section.as_str()).or_default() += row.amount_cents;
    }
    let sum = |sections: &[StatementSection]| -> i64 {
        sections
            .iter()
            .map(|s| sums.get(s.as_str()).copied().unwrap_or(0))
            .sum()
    };
    let new_charges = sum(&[Purchase, Installment, Cash, Fee]);
    let adjustment = -sum(&[Refund]);
    let interest = sum(&[Interest]);
    let amount_due =
        summary.previous_balance + sum(&[Repayment]) + new_charges - adjustment + interest;
    let check = |name: &str, expected: i64, actual: i64| ReconciliationCheck {
        name: name.to_string(),
        expected: expected as f64 / 100.0,
        actual: actual as f64 / 100.0,
        ok: expected == actual,
    };
    vec![
        check("本期新增", summary.new_charges, new_charges),
        check("本期调整", summary.adjustment, adjustment),
        check("循环利息", summary.interest, interest),
        check("本期应还", summary.amount_due, amount_due),
    ]
}

pub(crate) fn period_label(statement: &CmbStatement) -> String {
    format!(
        "{}–{}",
        statement.period_start.format("%Y/%m/%d"),
        statement.period_end.format("%Y/%m/%d")
    )
}

pub(crate) fn record_create(
    line: &StatementLine,
    direction: RecordDirection,
    category: String,
) -> RecordCreate {
    RecordCreate {
        direction,
        amount: line.amount,
        currency: STATS_CURRENCY.to_string(),
        category,
        merchant: Some(line.merchant.clone()),
        transaction_at: line.transaction_at,
        note: Some(line.note.clone()),
    }
}

fn card_label(rows: &[CmbRow]) -> String {
    let cards: std::collections::BTreeSet<&str> =
        rows.iter().map(|r| r.card_last4.as_str()).collect();
    format!("尾号{}", cards.into_iter().collect::<Vec<_>>().join("/"))
}

fn local_day(at: DateTime<Utc>, time_zone: Tz) -> NaiveDate {
    at.with_timezone(&time_zone).date_naive()
}

fn to_cents(amount: f64) -> i64 {
    (amount * 100.0).round() as i64
}

fn format_cents(cents: i64) -> String {
    let sign = if cents < 0 { "-" } else { "" };
    let abs = cents.unsigned_abs();
    format!("{sign}{}.{:02}", abs / 100, abs % 100)
}

#[cfg(test)]
mod tests;
