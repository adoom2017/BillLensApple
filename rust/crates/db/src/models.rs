use chrono::{DateTime, Datelike, NaiveDate, Utc};
use serde::{Deserialize, Deserializer, Serialize, de};
use uuid::Uuid;

pub const EXPENSE_CATEGORIES: &[&str] = &[
    "餐饮", "交通", "日用", "购物", "住房", "医疗", "娱乐", "教育", "通讯", "人情", "订阅", "其他",
];

pub const INCOME_CATEGORIES: &[&str] = &["工资收入", "投资收益", "报销", "退款", "其他"];

pub const ASSET_CATEGORIES: &[&str] = &["存款", "现金", "股票", "基金", "加密货币", "房产", "其他"];

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[serde(rename_all = "snake_case")]
pub enum EntityKind {
    Record,
    Subscription,
    Asset,
    AssetSnapshot,
    AppSetting,
}

impl EntityKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Record => "record",
            Self::Subscription => "subscription",
            Self::Asset => "asset",
            Self::AssetSnapshot => "asset_snapshot",
            Self::AppSetting => "app_setting",
        }
    }
}

pub fn is_valid_asset_category(category: &str) -> bool {
    ASSET_CATEGORIES.contains(&category.trim())
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SubscriptionCycle {
    Monthly,
    Yearly,
}

impl SubscriptionCycle {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Monthly => "monthly",
            Self::Yearly => "yearly",
        }
    }
}

impl TryFrom<&str> for SubscriptionCycle {
    type Error = &'static str;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "monthly" => Ok(Self::Monthly),
            "yearly" => Ok(Self::Yearly),
            _ => Err("invalid subscription cycle"),
        }
    }
}

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
    "订阅",
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

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ParsedDraftKind {
    Record,
    Asset,
    Subscription,
}

impl ParsedDraftKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Record => "record",
            Self::Asset => "asset",
            Self::Subscription => "subscription",
        }
    }
}

impl TryFrom<&str> for ParsedDraftKind {
    type Error = &'static str;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "record" => Ok(Self::Record),
            "asset" => Ok(Self::Asset),
            "subscription" => Ok(Self::Subscription),
            _ => Err("invalid parsed draft kind"),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ParserSource {
    Rule,
    Local,
    Cloud,
    CloudAfterLocalFailure,
}

impl ParserSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Rule => "rule",
            Self::Local => "local",
            Self::Cloud => "cloud",
            Self::CloudAfterLocalFailure => "cloud_after_local_failure",
        }
    }
}

impl TryFrom<&str> for ParserSource {
    type Error = &'static str;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "rule" => Ok(Self::Rule),
            "local" => Ok(Self::Local),
            "cloud" => Ok(Self::Cloud),
            "cloud_after_local_failure" => Ok(Self::CloudAfterLocalFailure),
            _ => Err("invalid parser source"),
        }
    }
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
    pub synced_version: i64,
    pub deleted_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordDraft {
    pub id: Uuid,
    pub batch_id: Uuid,
    pub profile_id: String,
    pub content: String,
    pub auto_confirm: bool,
    pub kind: ParsedDraftKind,
    pub parser_source: ParserSource,
    pub fallback_reason: Option<String>,
    pub status: RecordDraftStatus,
    pub confirmed_record_id: Option<Uuid>,
    pub direction: Option<RecordDirection>,
    pub amount: Option<f64>,
    pub currency: Option<String>,
    pub category: Option<String>,
    pub merchant: Option<String>,
    pub transaction_at: Option<DateTime<Utc>>,
    pub note: Option<String>,
    pub subscription_cycle: Option<SubscriptionCycle>,
    pub asset_info: Option<ParsedAssetInfo>,
    pub confirmation: Option<ParsedDraftConfirmation>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl RecordDraft {
    pub fn payload(&self) -> ParsedRecordPayload {
        ParsedRecordPayload {
            direction: self.direction.clone(),
            amount: self.amount,
            currency: self.currency.clone(),
            category: self.category.clone(),
            merchant: self.merchant.clone(),
            transaction_at: self.transaction_at,
            note: self.note.clone(),
            subscription_cycle: self.subscription_cycle.clone(),
            asset_info: self.asset_info.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default, deny_unknown_fields)]
pub struct ParsedDraftConfirmation {
    pub record_id: Option<Uuid>,
    pub asset_id: Option<Uuid>,
    pub asset_snapshot_id: Option<Uuid>,
    pub subscription_id: Option<Uuid>,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ParsedRecordPayload {
    pub direction: Option<RecordDirection>,
    pub amount: Option<f64>,
    pub currency: Option<String>,
    pub category: Option<String>,
    pub merchant: Option<String>,
    #[serde(default, deserialize_with = "deserialize_optional_transaction_at")]
    pub transaction_at: Option<DateTime<Utc>>,
    pub note: Option<String>,
    pub subscription_cycle: Option<SubscriptionCycle>,
    pub asset_info: Option<ParsedAssetInfo>,
}

fn deserialize_optional_transaction_at<'de, D>(
    deserializer: D,
) -> Result<Option<DateTime<Utc>>, D::Error>
where
    D: Deserializer<'de>,
{
    Option::<String>::deserialize(deserializer)?
        .map(|value| parse_transaction_at(&value).map_err(de::Error::custom))
        .transpose()
}

fn parse_transaction_at(value: &str) -> Result<DateTime<Utc>, &'static str> {
    if let Ok(parsed) = DateTime::parse_from_rfc3339(value) {
        return Ok(parsed.with_timezone(&Utc));
    }

    for format in [
        "%Y-%m-%dT%H:%M:%S%.f%z",
        "%Y-%m-%dT%H:%M%z",
        "%Y-%m-%d %H:%M:%S%.f%:z",
        "%Y-%m-%d %H:%M:%S%.f%z",
        "%Y-%m-%d %H:%M%:z",
        "%Y-%m-%d %H:%M%z",
    ] {
        if let Ok(parsed) = DateTime::parse_from_str(value, format) {
            return Ok(parsed.with_timezone(&Utc));
        }
    }

    // 不带时区偏移的时间存在歧义，不再按任何固定时区猜测。
    Err(
        "transaction_at must be RFC3339 or YYYY-MM-DD[ T]HH:MM[:SS[.fraction]] with an explicit UTC offset",
    )
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ParsedAssetInfo {
    pub name: String,
    pub category: Option<String>,
    pub amount: f64,
    pub currency: Option<String>,
    pub recorded_on: Option<String>,
    pub note: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AssetConfirmationCreate {
    pub name: String,
    pub category: String,
    pub amount: f64,
    pub currency: String,
    pub recorded_on: NaiveDate,
    pub note: Option<String>,
}

#[derive(Debug, Clone)]
pub enum ParsedDraftConfirmationAction {
    Record(RecordCreate),
    Asset(AssetConfirmationCreate),
    Subscription {
        record: RecordCreate,
        subscription: SubscriptionCreate,
    },
}

impl ParsedDraftConfirmationAction {
    pub fn kind(&self) -> ParsedDraftKind {
        match self {
            Self::Record(_) => ParsedDraftKind::Record,
            Self::Asset(_) => ParsedDraftKind::Asset,
            Self::Subscription { .. } => ParsedDraftKind::Subscription,
        }
    }
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
pub struct FxRateCache {
    pub base_currency: String,
    pub quote_currency: String,
    pub rate: f64,
    pub rate_date: NaiveDate,
    pub fetched_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncState {
    pub profile_id: String,
    pub last_cursor: Option<String>,
    pub last_synced_at: Option<DateTime<Utc>>,
    pub last_error: Option<String>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Subscription {
    pub id: Uuid,
    pub profile_id: String,
    pub direction: RecordDirection,
    pub amount: f64,
    pub currency: String,
    pub category: String,
    pub merchant: Option<String>,
    pub note: Option<String>,
    pub cycle: SubscriptionCycle,
    pub anchor_day: i32,
    pub anchor_month: Option<i32>,
    pub next_due_at: NaiveDate,
    pub last_charged_at: Option<NaiveDate>,
    pub is_active: bool,
    pub deleted_at: Option<DateTime<Utc>>,
    pub sync_version: i64,
    pub synced_version: i64,
    pub device_id: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubscriptionCreate {
    pub direction: RecordDirection,
    pub amount: f64,
    pub currency: String,
    pub category: String,
    pub merchant: Option<String>,
    pub note: Option<String>,
    pub cycle: SubscriptionCycle,
    pub anchor_day: i32,
    pub anchor_month: Option<i32>,
    pub next_due_at: NaiveDate,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubscriptionChargeAdvance {
    pub subscription_id: Uuid,
    pub last_charged_at: NaiveDate,
    pub next_due_at: NaiveDate,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SubscriptionUpdate {
    pub direction: Option<RecordDirection>,
    pub amount: Option<f64>,
    pub currency: Option<String>,
    pub category: Option<String>,
    pub merchant: Option<String>,
    pub note: Option<String>,
    pub cycle: Option<SubscriptionCycle>,
    pub anchor_day: Option<i32>,
    pub anchor_month: Option<i32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Asset {
    pub id: Uuid,
    pub profile_id: String,
    pub name: String,
    pub category: String,
    pub currency: String,
    pub note: Option<String>,
    pub deleted_at: Option<DateTime<Utc>>,
    pub sync_version: i64,
    pub synced_version: i64,
    pub device_id: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AssetSnapshot {
    pub id: Uuid,
    pub asset_id: Uuid,
    pub profile_id: String,
    pub amount: f64,
    pub recorded_on: String,
    pub note: Option<String>,
    pub deleted_at: Option<DateTime<Utc>>,
    pub sync_version: i64,
    pub synced_version: i64,
    pub device_id: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSetting {
    pub key: String,
    pub value: String,
    pub sync_version: i64,
    pub synced_version: i64,
    pub deleted_at: Option<DateTime<Utc>>,
    pub device_id: String,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AssetWithSnapshots {
    pub id: Uuid,
    pub profile_id: String,
    pub name: String,
    pub category: String,
    pub currency: String,
    pub note: Option<String>,
    pub snapshots: Vec<AssetSnapshot>,
    pub latest_amount: Option<f64>,
    pub latest_recorded_on: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AssetUpdateInput {
    pub name: Option<String>,
    pub category: Option<String>,
    pub currency: Option<String>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AssetAck {
    pub asset_id: Uuid,
    pub name: String,
    pub category: String,
    pub amount: f64,
    pub currency: String,
    pub recorded_on: String,
    pub created: bool,
}

/// Calculate the next due date after a given reference date.
pub fn advance_next_due(
    cycle: &SubscriptionCycle,
    anchor_day: i32,
    anchor_month: Option<i32>,
    from: NaiveDate,
) -> NaiveDate {
    match cycle {
        SubscriptionCycle::Monthly => {
            let mut year = from.year();
            let mut month = from.month() as i32 + 1;
            if month > 12 {
                month = 1;
                year += 1;
            }
            let day = clamp_day(year, month as u32, anchor_day as u32);
            NaiveDate::from_ymd_opt(year, month as u32, day).unwrap()
        }
        SubscriptionCycle::Yearly => {
            let target_month = anchor_month.unwrap_or(from.month() as i32) as u32;
            let next_year = from.year() + 1;
            let day = clamp_day(next_year, target_month, anchor_day as u32);
            NaiveDate::from_ymd_opt(next_year, target_month, day).unwrap()
        }
    }
}

fn clamp_day(year: i32, month: u32, day: u32) -> u32 {
    let max_day = last_day_of_month(year, month);
    day.min(max_day)
}

fn last_day_of_month(year: i32, month: u32) -> u32 {
    if month == 12 {
        31
    } else {
        NaiveDate::from_ymd_opt(year, month + 1, 1)
            .unwrap()
            .pred_opt()
            .unwrap()
            .day()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_transaction_at_accepts_explicit_offsets() {
        let cases = [
            ("2026-07-14T14:38:45+08:00", "2026-07-14T06:38:45+00:00"),
            ("2026-07-14T06:38:45Z", "2026-07-14T06:38:45+00:00"),
            ("2026-07-14T14:38:45+0800", "2026-07-14T06:38:45+00:00"),
            ("2026-07-14 14:38:45+08:00", "2026-07-14T06:38:45+00:00"),
            (
                "2026-07-14T14:38:45.123456-04:00",
                "2026-07-14T18:38:45.123456+00:00",
            ),
        ];

        for (input, expected) in cases {
            assert_eq!(parse_transaction_at(input).unwrap().to_rfc3339(), expected);
        }
    }

    #[test]
    fn parse_transaction_at_rejects_values_without_offset() {
        for value in [
            "2026-07-14T14:38:45",
            "2026-07-14 14:38",
            "2026-07-14",
            "2026/07/14 14:38:45",
            "14 Jul 2026 14:38:45",
            "2026-02-30T14:38:45+08:00",
            "",
        ] {
            let error = parse_transaction_at(value).unwrap_err();
            assert!(error.contains("explicit UTC offset"), "{value}");
        }
    }

    #[test]
    fn advance_next_due_monthly_normal() {
        let current = NaiveDate::from_ymd_opt(2026, 3, 15).unwrap();
        let next = advance_next_due(&SubscriptionCycle::Monthly, 15, None, current);
        assert_eq!(next, NaiveDate::from_ymd_opt(2026, 4, 15).unwrap());
    }

    #[test]
    fn advance_next_due_monthly_clamps_to_month_end() {
        let current = NaiveDate::from_ymd_opt(2026, 1, 31).unwrap();
        let next = advance_next_due(&SubscriptionCycle::Monthly, 31, None, current);
        assert_eq!(next, NaiveDate::from_ymd_opt(2026, 2, 28).unwrap());
    }

    #[test]
    fn advance_next_due_monthly_leap_year_feb() {
        let current = NaiveDate::from_ymd_opt(2028, 1, 31).unwrap();
        let next = advance_next_due(&SubscriptionCycle::Monthly, 31, None, current);
        assert_eq!(next, NaiveDate::from_ymd_opt(2028, 2, 29).unwrap());
    }

    #[test]
    fn advance_next_due_monthly_december_to_january() {
        let current = NaiveDate::from_ymd_opt(2026, 12, 10).unwrap();
        let next = advance_next_due(&SubscriptionCycle::Monthly, 10, None, current);
        assert_eq!(next, NaiveDate::from_ymd_opt(2027, 1, 10).unwrap());
    }

    #[test]
    fn advance_next_due_yearly_normal() {
        let current = NaiveDate::from_ymd_opt(2026, 6, 15).unwrap();
        let next = advance_next_due(&SubscriptionCycle::Yearly, 15, Some(6), current);
        assert_eq!(next, NaiveDate::from_ymd_opt(2027, 6, 15).unwrap());
    }

    #[test]
    fn advance_next_due_yearly_feb29_non_leap() {
        let current = NaiveDate::from_ymd_opt(2028, 2, 29).unwrap();
        let next = advance_next_due(&SubscriptionCycle::Yearly, 29, Some(2), current);
        assert_eq!(next, NaiveDate::from_ymd_opt(2029, 2, 28).unwrap());
    }
}
