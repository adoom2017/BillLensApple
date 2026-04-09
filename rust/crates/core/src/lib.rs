mod llm;
mod logger;
pub mod stt;

use anyhow::Result;
use billlens_apple_db::{
    ALL_RECORD_CATEGORIES, BillRepository, ConversationMessage, ConversationRole, EXPENSE_CATEGORIES, INCOME_CATEGORIES, ParsedRecordPayload,
    Record, RecordCreate, RecordDirection, RecordDraft, RecordDraftStatus, RecordDraftUpdate,
    RecordsStatsRange, RecordsStatsResponse, is_valid_record_category,
    is_valid_record_category_for_direction,
};
use chrono::{DateTime, Datelike, Duration, FixedOffset, NaiveDate, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use uuid::Uuid;
use llm::LlmClient;
pub use llm::LlmConfig;

#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("{0}")]
    BadRequest(String),
    #[error("{0}")]
    Internal(String),
}

impl CoreError {
    fn bad_request(message: impl Into<String>) -> Self {
        Self::BadRequest(message.into())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HomeSnapshot {
    pub messages: Vec<ConversationMessage>,
    pub draft: Option<RecordDraft>,
    pub latest_record: Option<Record>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubmitTextResult {
    pub home: HomeSnapshot,
    pub auto_confirmed: bool,
    pub parsed: ParsedRecordPayload,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SaveDraftResult {
    pub home: HomeSnapshot,
    pub record: Option<Record>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LedgerRangeSelection {
    pub preset: String,
    pub start_at: DateTime<FixedOffset>,
    pub end_at: DateTime<FixedOffset>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LedgerDayGroup {
    pub day: NaiveDate,
    pub income_amount: f64,
    pub expense_amount: f64,
    pub net_amount: f64,
    pub records: Vec<Record>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LedgerSnapshot {
    pub range: LedgerRangeSelection,
    pub summary: RecordsStatsResponse,
    pub by_day: Vec<LedgerDayGroup>,
    pub pending_sync_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DraftInput {
    pub direction: Option<RecordDirection>,
    pub amount: Option<f64>,
    pub currency: Option<String>,
    pub category: Option<String>,
    pub merchant: Option<String>,
    pub transaction_at: Option<DateTime<Utc>>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntrySource {
    Text,
    Ocr,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngineBootstrap {
    pub device_id: String,
    pub llm: Option<LlmConfig>,
    pub log_file_path: Option<String>,
}

#[derive(Clone)]
pub struct AppService {
    repo: BillRepository,
    device_id: String,
    llm: Option<LlmClient>,
}

impl AppService {
    pub fn new(repo: BillRepository, bootstrap: EngineBootstrap) -> Result<Self> {
        logger::initialize(bootstrap.log_file_path.as_deref())?;
        let llm = bootstrap.llm.map(LlmClient::from_config).transpose()?;
        Ok(Self {
            repo,
            device_id: bootstrap.device_id,
            llm,
        })
    }

    pub async fn bootstrap(&self, profile_id: &str) -> Result<()> {
        self.repo.ensure_sync_state(profile_id).await
    }

    pub async fn home(&self, profile_id: &str) -> Result<HomeSnapshot> {
        let messages = self.repo.list_conversation_messages(profile_id, 100).await?;
        let draft = self.repo.latest_active_record_draft(profile_id).await?;
        let latest_record = self.repo.latest_record(profile_id).await?;
        Ok(HomeSnapshot {
            messages,
            draft,
            latest_record,
        })
    }

    pub async fn submit_text(
        &self,
        profile_id: &str,
        content: String,
        auto_confirm: bool,
        source: EntrySource,
    ) -> Result<SubmitTextResult, CoreError> {
        let content = trim_required(content, "content is required")?;
        logger::info(
            "submit_text",
            format!("source={source:?} auto_confirm={auto_confirm} content={content}"),
        );
        let user_visible_content = match source {
            EntrySource::Text => content.clone(),
            EntrySource::Ocr => "已上传票据图片，正在执行 OCR 与 LLM 结构化解析。".to_string(),
        };
        self.repo
            .create_conversation_message(
                Uuid::new_v4(),
                profile_id,
                ConversationRole::User,
                &user_visible_content,
                None,
                None,
            )
            .await
            .map_err(map_internal)?;

        let llm = self
            .llm
            .as_ref()
            .ok_or_else(|| CoreError::bad_request("LLM parser is not configured"))?;
        let parsed = match source {
            EntrySource::Text => llm.parse_record_text(content.clone()).await,
            EntrySource::Ocr => llm.parse_record_ocr_text(content.clone()).await,
        }
        .map_err(map_internal)?;
        logger::info(
            "submit_text",
            format!(
                "parsed_payload={}",
                serde_json::to_string(&parsed).unwrap_or_else(|_| "<serialize failed>".to_string())
            ),
        );
        let summary = format_parsed_summary(&parsed);
        if auto_confirm {
            let create = record_create_from_parsed(&parsed)?;
            let record = self
                .repo
                .create_record(Uuid::new_v4(), profile_id, &self.device_id, create)
                .await
                .map_err(map_internal)?;
            self.repo
                .create_conversation_message(
                    Uuid::new_v4(),
                    profile_id,
                    ConversationRole::Assistant,
                    &format!("已根据当前输入自动保存账单。{summary}"),
                    None,
                    Some(record.id),
                )
                .await
                .map_err(map_internal)?;
            let home = self.home(profile_id).await.map_err(map_internal)?;
            return Ok(SubmitTextResult {
                home,
                auto_confirmed: true,
                parsed,
            });
        }

        let draft = self
            .repo
            .create_record_draft(Uuid::new_v4(), profile_id, &content, false, &parsed)
            .await
            .map_err(map_internal)?;
        self.repo
            .create_conversation_message(
                Uuid::new_v4(),
                profile_id,
                ConversationRole::Assistant,
                &format!("已生成待确认账单。{summary}"),
                Some(draft.id),
                None,
            )
            .await
            .map_err(map_internal)?;

        let home = self.home(profile_id).await.map_err(map_internal)?;
        Ok(SubmitTextResult {
            home,
            auto_confirmed: false,
            parsed,
        })
    }

    pub async fn save_draft(
        &self,
        profile_id: &str,
        draft_id: Uuid,
        input: DraftInput,
    ) -> Result<SaveDraftResult, CoreError> {
        let existing = self
            .repo
            .get_record_draft(draft_id)
            .await
            .map_err(map_internal)?;
        if existing.status != RecordDraftStatus::Parsed {
            return Err(CoreError::bad_request("only parsed drafts can be edited"));
        }

        let update = merge_draft_input(&existing, input)?;
        self.repo
            .update_record_draft(draft_id, update)
            .await
            .map_err(map_internal)?;
        let home = self.home(profile_id).await.map_err(map_internal)?;
        Ok(SaveDraftResult { home, record: None })
    }

    pub async fn confirm_draft(
        &self,
        profile_id: &str,
        draft_id: Uuid,
    ) -> Result<SaveDraftResult, CoreError> {
        let draft = self
            .repo
            .get_record_draft(draft_id)
            .await
            .map_err(map_internal)?;
        if draft.status != RecordDraftStatus::Parsed {
            return Err(CoreError::bad_request("draft is not confirmable"));
        }

        let create = record_create_from_draft(&draft)?;
        let record = self
            .repo
            .create_record(Uuid::new_v4(), profile_id, &self.device_id, create)
            .await
            .map_err(map_internal)?;
        self.repo
            .mark_record_draft_confirmed(draft_id, record.id)
            .await
            .map_err(map_internal)?;
        self.repo
            .create_conversation_message(
                Uuid::new_v4(),
                profile_id,
                ConversationRole::Assistant,
                "账单已确认入库。",
                Some(draft_id),
                Some(record.id),
            )
            .await
            .map_err(map_internal)?;

        let home = self.home(profile_id).await.map_err(map_internal)?;
        Ok(SaveDraftResult {
            home,
            record: Some(record),
        })
    }

    pub async fn discard_draft(&self, profile_id: &str, draft_id: Uuid) -> Result<HomeSnapshot, CoreError> {
        let draft = self
            .repo
            .get_record_draft(draft_id)
            .await
            .map_err(map_internal)?;
        if draft.status != RecordDraftStatus::Parsed {
            return Err(CoreError::bad_request("draft is not discardable"));
        }
        self.repo
            .discard_record_draft(draft_id)
            .await
            .map_err(map_internal)?;
        self.repo
            .create_conversation_message(
                Uuid::new_v4(),
                profile_id,
                ConversationRole::Assistant,
                "已丢弃当前草稿。",
                Some(draft_id),
                None,
            )
            .await
            .map_err(map_internal)?;
        self.home(profile_id).await.map_err(map_internal)
    }

    pub async fn ledger(
        &self,
        profile_id: &str,
        preset: &str,
        start_at: Option<DateTime<FixedOffset>>,
        end_at: Option<DateTime<FixedOffset>>,
    ) -> Result<LedgerSnapshot, CoreError> {
        let range = build_ledger_range(preset, start_at, end_at)?;
        let stats_range = RecordsStatsRange {
            start_at: range.start_at.with_timezone(&Utc),
            end_at: range.end_at.with_timezone(&Utc),
        };
        let records = self
            .repo
            .list_records(profile_id, &stats_range, None, None)
            .await
            .map_err(map_internal)?;
        let summary = self
            .repo
            .record_stats(profile_id, stats_range.clone(), None, None)
            .await
            .map_err(map_internal)?;
        let pending_sync_count = self
            .repo
            .pending_sync_count(profile_id)
            .await
            .map_err(map_internal)?;

        let mut grouped = BTreeMap::<NaiveDate, Vec<Record>>::new();
        for record in records {
            grouped
                .entry(record.transaction_at.with_timezone(&shanghai_offset()).date_naive())
                .or_default()
                .push(record);
        }

        let by_day = grouped
            .into_iter()
            .rev()
            .map(|(day, records)| {
                let income_amount = sum_amount(&records, RecordDirection::Income);
                let expense_amount = sum_amount(&records, RecordDirection::Expense);
                LedgerDayGroup {
                    day,
                    income_amount,
                    expense_amount,
                    net_amount: income_amount - expense_amount,
                    records,
                }
            })
            .collect();

        Ok(LedgerSnapshot {
            range,
            summary,
            by_day,
            pending_sync_count,
        })
    }
}

fn sum_amount(records: &[Record], direction: RecordDirection) -> f64 {
    records
        .iter()
        .filter(|record| record.direction == direction)
        .map(|record| record.amount)
        .sum()
}

fn build_ledger_range(
    preset: &str,
    start_at: Option<DateTime<FixedOffset>>,
    end_at: Option<DateTime<FixedOffset>>,
) -> Result<LedgerRangeSelection, CoreError> {
    let now = Utc::now().with_timezone(&shanghai_offset());
    let today = now.date_naive();
    let preset = preset.trim().to_ascii_lowercase();
    let (start_at, end_at) = match preset.as_str() {
        "week" => {
            let weekday = today.weekday().num_days_from_monday() as i64;
            let start = today - Duration::days(weekday);
            (at_start_of_day(start)?, now)
        }
        "month" => (
            at_start_of_day(NaiveDate::from_ymd_opt(today.year(), today.month(), 1).unwrap())?,
            now,
        ),
        "year" => (
            at_start_of_day(NaiveDate::from_ymd_opt(today.year(), 1, 1).unwrap())?,
            now,
        ),
        "custom" => {
            let start_at = start_at.ok_or_else(|| CoreError::bad_request("start_at is required"))?;
            let end_at = end_at.ok_or_else(|| CoreError::bad_request("end_at is required"))?;
            if start_at > end_at {
                return Err(CoreError::bad_request(
                    "start_at must be earlier than or equal to end_at",
                ));
            }
            (start_at, end_at)
        }
        _ => return Err(CoreError::bad_request("preset must be week, month, year or custom")),
    };

    Ok(LedgerRangeSelection {
        preset,
        start_at,
        end_at,
    })
}

fn at_start_of_day(date: NaiveDate) -> Result<DateTime<FixedOffset>, CoreError> {
    shanghai_offset()
        .with_ymd_and_hms(date.year(), date.month(), date.day(), 0, 0, 0)
        .single()
        .ok_or_else(|| CoreError::bad_request("failed to build range boundary"))
}

fn shanghai_offset() -> FixedOffset {
    FixedOffset::east_opt(8 * 3600).unwrap()
}

fn trim_required(value: String, message: &str) -> Result<String, CoreError> {
    let trimmed = value.trim().to_string();
    if trimmed.is_empty() {
        return Err(CoreError::bad_request(message));
    }
    Ok(trimmed)
}

fn trim_optional(value: Option<String>) -> Option<String> {
    value.and_then(|value| {
        let trimmed = value.trim().to_string();
        (!trimmed.is_empty()).then_some(trimmed)
    })
}

fn validate_category_for_direction(
    category: &str,
    direction: Option<&RecordDirection>,
) -> Result<String, CoreError> {
    let category = category.trim();
    if category.is_empty() {
        return Err(CoreError::bad_request("category is required"));
    }
    if !is_valid_record_category(category) {
        return Err(CoreError::bad_request(format!(
            "category must be one of: {}",
            ALL_RECORD_CATEGORIES.join("、")
        )));
    }
    if !is_valid_record_category_for_direction(direction, category) {
        let allowed = match direction {
            Some(RecordDirection::Expense) => EXPENSE_CATEGORIES.join("、"),
            Some(RecordDirection::Income) => INCOME_CATEGORIES.join("、"),
            None => ALL_RECORD_CATEGORIES.join("、"),
        };
        return Err(CoreError::bad_request(format!(
            "category is invalid for direction, allowed categories: {allowed}"
        )));
    }
    Ok(category.to_string())
}

fn merge_draft_input(existing: &RecordDraft, input: DraftInput) -> Result<RecordDraftUpdate, CoreError> {
    let direction = input.direction.or_else(|| existing.direction.clone());
    let amount = input.amount.or(existing.amount);
    if let Some(amount) = amount {
        if amount <= 0.0 {
            return Err(CoreError::bad_request("amount must be greater than 0"));
        }
    }
    let category = input
        .category
        .or_else(|| existing.category.clone())
        .map(|value| validate_category_for_direction(&value, direction.as_ref()))
        .transpose()?;

    Ok(RecordDraftUpdate {
        direction,
        amount,
        currency: trim_optional(input.currency).or_else(|| existing.currency.clone()),
        category,
        merchant: trim_optional(input.merchant).or_else(|| existing.merchant.clone()),
        transaction_at: input.transaction_at.or(existing.transaction_at),
        note: trim_optional(input.note).or_else(|| existing.note.clone()),
    })
}

fn record_create_from_draft(payload: &RecordDraft) -> Result<RecordCreate, CoreError> {
    let direction = payload
        .direction
        .clone()
        .ok_or_else(|| CoreError::bad_request("draft direction is required"))?;
    let amount = payload
        .amount
        .filter(|amount| *amount > 0.0)
        .ok_or_else(|| CoreError::bad_request("draft amount must be greater than 0"))?;
    let category = payload
        .category
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| CoreError::bad_request("draft category is required"))?
        .to_string();
    let category = validate_category_for_direction(&category, Some(&direction))?;
    let transaction_at = payload
        .transaction_at
        .ok_or_else(|| CoreError::bad_request("draft transaction_at is required"))?;

    Ok(RecordCreate {
        direction,
        amount,
        currency: payload
            .currency
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or("CNY")
            .to_string(),
        category,
        merchant: trim_optional(payload.merchant.clone()),
        transaction_at,
        note: trim_optional(payload.note.clone()),
    })
}

fn record_create_from_parsed(payload: &ParsedRecordPayload) -> Result<RecordCreate, CoreError> {
    let direction = payload
        .direction
        .clone()
        .ok_or_else(|| CoreError::bad_request("parsed direction is required"))?;
    let amount = payload
        .amount
        .filter(|amount| *amount > 0.0)
        .ok_or_else(|| CoreError::bad_request("parsed amount must be greater than 0"))?;
    let category = payload
        .category
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| CoreError::bad_request("parsed category is required"))?
        .to_string();
    let category = validate_category_for_direction(&category, Some(&direction))?;
    let transaction_at = payload.transaction_at.unwrap_or_else(Utc::now);

    Ok(RecordCreate {
        direction,
        amount,
        currency: payload
            .currency
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or("CNY")
            .to_string(),
        category,
        merchant: trim_optional(payload.merchant.clone()),
        transaction_at,
        note: trim_optional(payload.note.clone()),
    })
}

fn format_parsed_summary(payload: &ParsedRecordPayload) -> String {
    let direction = match payload.direction {
        Some(RecordDirection::Income) => "收入",
        Some(RecordDirection::Expense) => "支出",
        None => "未知类型",
    };
    let amount = payload
        .amount
        .map(|value| format!("¥{value:.2}"))
        .unwrap_or_else(|| "金额待确认".to_string());
    let category = payload
        .category
        .clone()
        .unwrap_or_else(|| "分类待确认".to_string());
    let merchant = payload
        .merchant
        .clone()
        .unwrap_or_else(|| "商户待确认".to_string());
    let transaction_at = payload
        .transaction_at
        .map(|value| value.format("%Y-%m-%d %H:%M:%S").to_string())
        .unwrap_or_else(|| "时间待确认".to_string());

    format!(
        "解析结果：{direction} {amount}，分类：{category}，商户：{merchant}，时间：{transaction_at}。"
    )
}

fn map_internal(error: anyhow::Error) -> CoreError {
    logger::error("core", error.to_string());
    CoreError::Internal(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_custom_range_rejects_inverted_range() {
        let start = shanghai_offset().with_ymd_and_hms(2026, 4, 2, 0, 0, 0).unwrap();
        let end = shanghai_offset().with_ymd_and_hms(2026, 4, 1, 0, 0, 0).unwrap();
        let error = build_ledger_range("custom", Some(start), Some(end)).unwrap_err();
        assert_eq!(
            error.to_string(),
            "start_at must be earlier than or equal to end_at"
        );
    }
}
