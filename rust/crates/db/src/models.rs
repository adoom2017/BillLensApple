use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const EXPENSE_CATEGORIES: &[&str] = &[
    "餐饮", "交通", "日用", "购物", "住房", "医疗", "娱乐", "教育", "通讯", "人情", "其他",
];

pub const INCOME_CATEGORIES: &[&str] = &["工资收入", "投资收益", "报销", "退款", "其他"];

pub const ALL_RECORD_CATEGORIES: &[&str] = &[
    "餐饮",
    "交通",
    "日用",
    "购物",
    "住房",
    "医疗",
    "娱乐",
    "教育",
    "通讯",
    "人情",
    "工资收入",
    "投资收益",
    "报销",
    "退款",
    "其他",
];

pub fn is_valid_record_category(category: &str) -> bool {
    ALL_RECORD_CATEGORIES.contains(&category.trim())
}

pub fn is_valid_record_category_for_direction(
    direction: Option<&RecordDirection>,
    category: &str,
) -> bool {
    let category = category.trim();
    match direction {
        Some(RecordDirection::Expense) => EXPENSE_CATEGORIES.contains(&category),
        Some(RecordDirection::Income) => INCOME_CATEGORIES.contains(&category),
        None => ALL_RECORD_CATEGORIES.contains(&category),
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RecordDirection {
    Income,
    Expense,
}

impl RecordDirection {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Income => "income",
            Self::Expense => "expense",
        }
    }
}

impl TryFrom<&str> for RecordDirection {
    type Error = &'static str;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "income" => Ok(Self::Income),
            "expense" => Ok(Self::Expense),
            _ => Err("invalid record direction"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RecordDraftStatus {
    Parsed,
    Confirmed,
    Discarded,
}

impl RecordDraftStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Parsed => "parsed",
            Self::Confirmed => "confirmed",
            Self::Discarded => "discarded",
        }
    }
}

impl TryFrom<&str> for RecordDraftStatus {
    type Error = &'static str;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "parsed" => Ok(Self::Parsed),
            "confirmed" => Ok(Self::Confirmed),
            "discarded" => Ok(Self::Discarded),
            _ => Err("invalid record draft status"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ConversationRole {
    User,
    Assistant,
}

impl ConversationRole {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Assistant => "assistant",
        }
    }
}

impl TryFrom<&str> for ConversationRole {
    type Error = &'static str;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "user" => Ok(Self::User),
            "assistant" => Ok(Self::Assistant),
            _ => Err("invalid conversation role"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Record {
    pub id: Uuid,
    pub profile_id: String,
    pub direction: RecordDirection,
    pub amount: f64,
    pub currency: String,
    pub category: String,
    pub merchant: Option<String>,
    pub transaction_at: DateTime<Utc>,
    pub note: Option<String>,
    pub device_id: String,
    pub sync_version: i64,
    pub deleted_at: Option<DateTime<Utc>>,
    pub needs_sync: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordDraft {
    pub id: Uuid,
    pub profile_id: String,
    pub content: String,
    pub auto_confirm: bool,
    pub status: RecordDraftStatus,
    pub confirmed_record_id: Option<Uuid>,
    pub direction: Option<RecordDirection>,
    pub amount: Option<f64>,
    pub currency: Option<String>,
    pub category: Option<String>,
    pub merchant: Option<String>,
    pub transaction_at: Option<DateTime<Utc>>,
    pub note: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationMessage {
    pub id: Uuid,
    pub profile_id: String,
    pub role: ConversationRole,
    pub content: String,
    pub draft_id: Option<Uuid>,
    pub record_id: Option<Uuid>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordCreate {
    pub direction: RecordDirection,
    pub amount: f64,
    pub currency: String,
    pub category: String,
    pub merchant: Option<String>,
    pub transaction_at: DateTime<Utc>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordUpdate {
    pub direction: RecordDirection,
    pub amount: f64,
    pub currency: String,
    pub category: String,
    pub merchant: Option<String>,
    pub transaction_at: DateTime<Utc>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RecordDraftUpdate {
    pub direction: Option<RecordDirection>,
    pub amount: Option<f64>,
    pub currency: Option<String>,
    pub category: Option<String>,
    pub merchant: Option<String>,
    pub transaction_at: Option<DateTime<Utc>>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParsedRecordPayload {
    pub direction: Option<RecordDirection>,
    pub amount: Option<f64>,
    pub currency: Option<String>,
    pub category: Option<String>,
    pub merchant: Option<String>,
    pub transaction_at: Option<DateTime<Utc>>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordsStatsRange {
    pub start_at: DateTime<Utc>,
    pub end_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordsSummary {
    pub income_amount: f64,
    pub income_count: i64,
    pub expense_amount: f64,
    pub expense_count: i64,
    pub net_amount: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DirectionStatsItem {
    pub direction: RecordDirection,
    pub total_amount: f64,
    pub record_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CategoryStatsItem {
    pub category: String,
    pub direction: RecordDirection,
    pub total_amount: f64,
    pub record_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordsStatsResponse {
    pub range: RecordsStatsRange,
    pub summary: RecordsSummary,
    pub by_direction: Vec<DirectionStatsItem>,
    pub by_category: Vec<CategoryStatsItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncState {
    pub profile_id: String,
    pub last_cursor: Option<String>,
    pub last_synced_at: Option<DateTime<Utc>>,
    pub last_error: Option<String>,
    pub updated_at: DateTime<Utc>,
}
