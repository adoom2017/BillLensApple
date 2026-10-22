mod fx;
mod llm;
pub mod local_llm;
mod logger;
mod rule_parser;
pub mod stt;

use anyhow::{Result, anyhow};
pub use billlens_apple_db::{
    ALL_RECORD_CATEGORIES, ASSET_CATEGORIES, AppSetting, Asset, AssetAck, AssetConfirmationCreate,
    AssetSnapshot, AssetUpdateInput, AssetWithSnapshots, BillRepository, CategoryStatsItem,
    ConversationMessage, ConversationRole, DirectionStatsItem, EXPENSE_CATEGORIES, EntityKind,
    INCOME_CATEGORIES, ParsedAssetInfo, ParsedDraftConfirmationAction, ParsedDraftKind,
    ParsedRecordPayload, ParserSource, Record, RecordCreate, RecordDirection, RecordDraft,
    RecordDraftStatus, RecordDraftUpdate, RecordsStatsRange, RecordsStatsResponse, RecordsSummary,
    Subscription, SubscriptionChargeAdvance, SubscriptionCreate, SubscriptionCycle,
    SubscriptionUpdate, advance_next_due, is_valid_asset_category, is_valid_record_category,
    is_valid_record_category_for_direction,
};
use chrono::{DateTime, Datelike, FixedOffset, NaiveDate, TimeZone, Utc};
use chrono_tz::Tz;
use fx::{FxClient, resolve_fx_rate};
use llm::{
    CloudLlmClient, build_record_prompt, normalize_currency_code, parse_record_payloads_strict,
    validate_record_payload_contract,
};
pub use llm::{LlmConfig, LlmModelItem};
use rule_parser::{RuleHints, RuleOutcome};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;
use std::sync::{Arc, RwLock};
use uuid::Uuid;

const STATS_CURRENCY: &str = "CNY";

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
    pub drafts: Vec<RecordDraft>,
    pub latest_record: Option<Record>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubmitTextResult {
    pub home: HomeSnapshot,
    pub auto_confirmed: bool,
    pub parsed: Vec<ParsedRecordPayload>,
    pub subscription_created: bool,
    pub asset_acks: Vec<AssetAck>,
    pub parser_source: ParserSource,
    pub local_model_id: Option<String>,
    pub local_failure: Option<LocalFailureInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocalFailureInfo {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LocalRoutingMode {
    LocalFirst,
    CloudOnly,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocalRoutingRequest {
    pub mode: LocalRoutingMode,
    pub model_id: Option<String>,
}

#[derive(Debug)]
struct RoutedParseResult {
    payloads: Vec<ParsedRecordPayload>,
    parser_source: ParserSource,
    local_model_id: Option<String>,
    local_failure: Option<LocalFailureInfo>,
}

struct ParseRouter;

impl ParseRouter {
    async fn route<LocalCall, LocalFuture, CloudCall, CloudFuture>(
        routing: LocalRoutingRequest,
        now: DateTime<Tz>,
        mut local_call: LocalCall,
        mut cloud_call: CloudCall,
    ) -> Result<RoutedParseResult, CoreError>
    where
        LocalCall: FnMut(&str) -> LocalFuture,
        LocalFuture: Future<Output = Result<(String, String, u64), local_llm::LocalLlmError>>,
        CloudCall: FnMut() -> CloudFuture,
        CloudFuture: Future<Output = Result<Vec<ParsedRecordPayload>, CoreError>>,
    {
        if routing.mode == LocalRoutingMode::CloudOnly {
            return Ok(RoutedParseResult {
                payloads: cloud_call().await?,
                parser_source: ParserSource::Cloud,
                local_model_id: None,
                local_failure: None,
            });
        }

        let Some(model_id) = routing
            .model_id
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
        else {
            let local_failure = LocalFailureInfo {
                code: "model_not_selected".to_string(),
                message: "本地优先模式尚未选择已安装模型".to_string(),
            };
            let payloads = cloud_call().await.map_err(|error| {
                CoreError::Internal(format!("未选择本地模型；云端模型也失败（{error}）"))
            })?;
            return Ok(RoutedParseResult {
                payloads,
                parser_source: ParserSource::CloudAfterLocalFailure,
                local_model_id: None,
                local_failure: Some(local_failure),
            });
        };

        let local_failure = match local_call(&model_id).await {
            Ok((raw_content, returned_model_id, elapsed_ms)) => {
                logger::info(
                    "llm.local.response",
                    format!("model_id={returned_model_id} elapsed_ms={elapsed_ms}"),
                );
                match parse_record_payloads_strict(&raw_content, now) {
                    Ok(payloads) => {
                        return Ok(RoutedParseResult {
                            payloads,
                            parser_source: ParserSource::Local,
                            local_model_id: Some(returned_model_id),
                            local_failure: None,
                        });
                    }
                    Err(error) => {
                        logger::error(
                            "llm.local.output.raw",
                            local_output_log_message(&returned_model_id, &raw_content),
                        );
                        LocalFailureInfo {
                            code: "output_contract_failed".to_string(),
                            message: format!("{error:#}"),
                        }
                    }
                }
            }
            Err(error) => {
                if !error.code.allows_cloud_fallback() {
                    return Err(CoreError::Internal(error.to_string()));
                }
                LocalFailureInfo {
                    code: error.code.as_str().to_string(),
                    message: error.message,
                }
            }
        };

        logger::error(
            "llm.local.fallback",
            format!(
                "model_id={model_id} code={} message={}",
                local_failure.code, local_failure.message
            ),
        );
        let payloads = cloud_call().await.map_err(|error| {
            CoreError::Internal(format!(
                "本地模型解析失败（{}: {}）；云端模型也失败（{}）",
                local_failure.code, local_failure.message, error
            ))
        })?;
        Ok(RoutedParseResult {
            payloads,
            parser_source: ParserSource::CloudAfterLocalFailure,
            local_model_id: Some(model_id),
            local_failure: Some(local_failure),
        })
    }
}

fn local_output_log_message(model_id: &str, raw_content: &str) -> String {
    format!("model_id={model_id} content={raw_content}")
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
    pub stats_currency: String,
    pub fx_warning: Option<String>,
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
    pub subscription_cycle: Option<SubscriptionCycle>,
    pub asset_info: Option<ParsedAssetInfo>,
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
    /// 设备 IANA 时区（如 Asia/Shanghai），由 Swift 的 TimeZone.current.identifier 提供。
    pub time_zone: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncDirtyItem {
    pub entity_type: EntityKind,
    pub id: String,
    pub payload: String,
    pub sync_version: i64,
}

impl SyncDirtyItem {
    fn from_record(r: Record) -> anyhow::Result<Self> {
        Self::new(EntityKind::Record, r.id.to_string(), r.sync_version, &r)
    }
    fn from_subscription(s: Subscription) -> anyhow::Result<Self> {
        Self::new(
            EntityKind::Subscription,
            s.id.to_string(),
            s.sync_version,
            &s,
        )
    }
    fn from_asset(a: Asset) -> anyhow::Result<Self> {
        Self::new(EntityKind::Asset, a.id.to_string(), a.sync_version, &a)
    }
    fn from_asset_snapshot(s: AssetSnapshot) -> anyhow::Result<Self> {
        Self::new(
            EntityKind::AssetSnapshot,
            s.id.to_string(),
            s.sync_version,
            &s,
        )
    }
    fn from_app_setting(s: AppSetting) -> anyhow::Result<Self> {
        Self::new(EntityKind::AppSetting, s.key.clone(), s.sync_version, &s)
    }
    fn new(
        entity_type: EntityKind,
        id: String,
        sync_version: i64,
        payload: &impl Serialize,
    ) -> anyhow::Result<Self> {
        Ok(Self {
            entity_type,
            id,
            payload: serde_json::to_string(payload)?,
            sync_version,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SyncDirtyBatch {
    pub records: Vec<SyncDirtyItem>,
    pub subscriptions: Vec<SyncDirtyItem>,
    pub assets: Vec<SyncDirtyItem>,
    pub asset_snapshots: Vec<SyncDirtyItem>,
    pub app_settings: Vec<SyncDirtyItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncMarkSyncedEntry {
    pub entity_type: EntityKind,
    pub id: String,
    pub synced_version: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncRemoteEntry {
    pub entity_type: EntityKind,
    pub payload: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncApplyResult {
    pub applied: u32,
    pub skipped: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncStatus {
    pub pending_count: i64,
}

#[derive(Clone)]
pub struct AppService {
    repo: BillRepository,
    device_id: String,
    llm: Option<CloudLlmClient>,
    fx: FxClient,
    /// 本地日期（账本按天分组、月/年范围、订阅扣费日）都按此时区计算，含夏令时规则。
    time_zone: Arc<RwLock<Tz>>,
}

fn parse_time_zone(name: &str) -> Result<Tz, CoreError> {
    name.parse::<Tz>()
        .map_err(|error| CoreError::bad_request(format!("invalid time_zone {name:?}: {error}")))
}

impl AppService {
    pub fn new(repo: BillRepository, bootstrap: EngineBootstrap) -> Result<Self> {
        logger::initialize(bootstrap.log_file_path.as_deref())?;
        let llm = bootstrap.llm.map(CloudLlmClient::from_config).transpose()?;
        let time_zone =
            parse_time_zone(&bootstrap.time_zone).map_err(|error| anyhow!("{error}"))?;
        logger::info("engine.time_zone", time_zone.name());
        Ok(Self {
            repo,
            device_id: bootstrap.device_id,
            llm,
            fx: FxClient::new(),
            time_zone: Arc::new(RwLock::new(time_zone)),
        })
    }

    /// 系统时区变化（如出行）时由 Swift 调用。
    pub fn set_time_zone(&self, name: &str) -> Result<(), CoreError> {
        let time_zone = parse_time_zone(name)?;
        *self.time_zone.write().expect("time zone lock poisoned") = time_zone;
        logger::info("engine.time_zone", time_zone.name());
        Ok(())
    }

    fn time_zone(&self) -> Tz {
        *self.time_zone.read().expect("time zone lock poisoned")
    }

    pub async fn bootstrap(&self, profile_id: &str) -> Result<()> {
        self.repo.ensure_sync_state(profile_id).await?;
        Ok(())
    }

    pub async fn home(&self, profile_id: &str) -> Result<HomeSnapshot> {
        let messages = self
            .repo
            .list_conversation_messages(profile_id, 100)
            .await?;
        let drafts = self.repo.list_active_record_drafts(profile_id).await?;
        let latest_record = self.repo.latest_record(profile_id).await?;
        Ok(HomeSnapshot {
            messages,
            drafts,
            latest_record,
        })
    }

    pub async fn submit_text(
        &self,
        profile_id: &str,
        content: String,
        auto_confirm: bool,
        source: EntrySource,
        routing: LocalRoutingRequest,
    ) -> Result<SubmitTextResult, CoreError> {
        let content = trim_required(content, "content is required")?;
        let time_zone = self.time_zone();
        logger::info(
            "submit_text",
            format!(
                "source={source:?} auto_confirm={auto_confirm} characters={}",
                content.chars().count()
            ),
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

        let now = Utc::now().with_timezone(&time_zone);
        let routed = self
            .parse_with_rules(&content, &source, routing, now)
            .await?;
        let payloads = routed.payloads;

        if payloads.is_empty() {
            return Err(CoreError::bad_request(
                "未能从输入中识别出任何账单记录，请检查图片或文字内容后重试。",
            ));
        }

        logger::info("submit_text", format!("parsed_count={}", payloads.len()));

        if routed.parser_source == ParserSource::Local {
            let drafts = self
                .repo
                .create_parsed_drafts_batch(
                    profile_id,
                    &content,
                    &payloads,
                    ParserSource::Local,
                    None,
                )
                .await
                .map_err(map_internal)?;
            self.repo
                .create_conversation_message(
                    Uuid::new_v4(),
                    profile_id,
                    ConversationRole::Assistant,
                    &format!("本地模型已生成 {} 项待确认结果。", drafts.len()),
                    drafts.first().map(|draft| draft.id),
                    None,
                )
                .await
                .map_err(map_internal)?;
            let home = self.home(profile_id).await.map_err(map_internal)?;
            return Ok(SubmitTextResult {
                home,
                auto_confirmed: false,
                parsed: payloads,
                subscription_created: false,
                asset_acks: Vec::new(),
                parser_source: routed.parser_source,
                local_model_id: routed.local_model_id,
                local_failure: routed.local_failure,
            });
        }

        // Process asset payloads first; they do not become bills or subscriptions.
        let mut asset_acks: Vec<AssetAck> = Vec::new();
        let mut bill_payloads: Vec<ParsedRecordPayload> = Vec::with_capacity(payloads.len());
        for payload in payloads.iter() {
            if let Some(ref asset_info) = payload.asset_info {
                let ack = self
                    .upsert_asset_from_payload(profile_id, asset_info)
                    .await?;
                logger::info(
                    "submit_text.asset",
                    format!(
                        "{} asset={} amount={} recorded_on={}",
                        if ack.created { "created" } else { "updated" },
                        ack.name,
                        ack.amount,
                        ack.recorded_on
                    ),
                );
                asset_acks.push(ack);
            } else {
                bill_payloads.push(payload.clone());
            }
        }

        // If only asset records were parsed, respond early without touching bill/draft path.
        if bill_payloads.is_empty() {
            let ack_summary = format_asset_acks_summary(&asset_acks);
            self.repo
                .create_conversation_message(
                    Uuid::new_v4(),
                    profile_id,
                    ConversationRole::Assistant,
                    &ack_summary,
                    None,
                    None,
                )
                .await
                .map_err(map_internal)?;
            let home = self.home(profile_id).await.map_err(map_internal)?;
            return Ok(SubmitTextResult {
                home,
                auto_confirmed: false,
                parsed: payloads,
                subscription_created: false,
                asset_acks,
                parser_source: routed.parser_source,
                local_model_id: routed.local_model_id,
                local_failure: routed.local_failure,
            });
        }

        let summary = format_multi_parsed_summary(&bill_payloads, &time_zone);
        let asset_tail = if asset_acks.is_empty() {
            String::new()
        } else {
            format!("\n{}", format_asset_acks_summary(&asset_acks))
        };

        // Create subscriptions for any payload with subscription_cycle detected
        let mut subscription_created = false;
        for payload in &bill_payloads {
            if let Some(ref cycle) = payload.subscription_cycle {
                {
                    let direction = payload.direction.as_ref().ok_or_else(|| {
                        CoreError::bad_request("subscription direction is required")
                    })?;
                    let amount = payload.amount.filter(|value| *value > 0.0).ok_or_else(|| {
                        CoreError::bad_request("subscription amount must be greater than 0")
                    })?;
                    let currency = validate_required_currency(payload.currency.as_deref())?;
                    let transaction_at = payload.transaction_at.ok_or_else(|| {
                        CoreError::bad_request("subscription transaction_at is required")
                    })?;
                    let category = payload.category.as_deref().ok_or_else(|| {
                        CoreError::bad_request("subscription category is required")
                    })?;
                    let local_time = transaction_at.with_timezone(&time_zone);
                    let today = local_time.date_naive();
                    let anchor_day = local_time.day() as i32;
                    let anchor_month = match cycle {
                        SubscriptionCycle::Yearly => Some(local_time.month() as i32),
                        SubscriptionCycle::Monthly => None,
                    };
                    let next_due = advance_next_due(cycle, anchor_day, anchor_month, today);
                    let sub_create = SubscriptionCreate {
                        direction: direction.clone(),
                        amount,
                        currency,
                        category: validate_category_for_direction(category, Some(direction))?,
                        merchant: payload.merchant.clone(),
                        note: payload.note.clone(),
                        cycle: cycle.clone(),
                        anchor_day,
                        anchor_month,
                        next_due_at: next_due,
                    };
                    self.repo
                        .create_subscription(
                            Uuid::new_v4(),
                            profile_id,
                            &self.device_id,
                            sub_create,
                        )
                        .await
                        .map_err(map_internal)?;
                    subscription_created = true;
                    logger::info(
                        "submit_text.subscription",
                        format!("created subscription cycle={}", cycle.as_str()),
                    );
                }
            }
        }

        if auto_confirm {
            // Validate all payloads before touching the DB so a bad payload never
            // leaves earlier records committed while the rest fail.
            let creates: Vec<RecordCreate> = bill_payloads
                .iter()
                .map(record_create_from_parsed)
                .collect::<Result<_, _>>()?;
            let mut last_record_id = None;
            for create in creates {
                let record = self
                    .repo
                    .create_record(Uuid::new_v4(), profile_id, &self.device_id, create)
                    .await
                    .map_err(map_internal)?;
                last_record_id = Some(record.id);
            }
            self.repo
                .create_conversation_message(
                    Uuid::new_v4(),
                    profile_id,
                    ConversationRole::Assistant,
                    &format!(
                        "已自动保存 {} 笔账单。{summary}{asset_tail}",
                        bill_payloads.len()
                    ),
                    None,
                    last_record_id,
                )
                .await
                .map_err(map_internal)?;
            let home = self.home(profile_id).await.map_err(map_internal)?;
            return Ok(SubmitTextResult {
                home,
                auto_confirmed: true,
                parsed: payloads,
                subscription_created,
                asset_acks,
                parser_source: routed.parser_source,
                local_model_id: routed.local_model_id,
                local_failure: routed.local_failure,
            });
        }

        let fallback_reason = routed
            .local_failure
            .as_ref()
            .map(|failure| format!("{}: {}", failure.code, failure.message));
        let drafts = self
            .repo
            .create_parsed_drafts_batch(
                profile_id,
                &content,
                &bill_payloads,
                routed.parser_source,
                fallback_reason.as_deref(),
            )
            .await
            .map_err(map_internal)?;
        let first_draft_id = drafts.first().map(|d| d.id);
        self.repo
            .create_conversation_message(
                Uuid::new_v4(),
                profile_id,
                ConversationRole::Assistant,
                &format!(
                    "已生成 {} 笔待确认账单。{summary}{asset_tail}",
                    bill_payloads.len()
                ),
                first_draft_id,
                None,
            )
            .await
            .map_err(map_internal)?;

        let home = self.home(profile_id).await.map_err(map_internal)?;
        Ok(SubmitTextResult {
            home,
            auto_confirmed: false,
            parsed: payloads,
            subscription_created,
            asset_acks,
            parser_source: routed.parser_source,
            local_model_id: routed.local_model_id,
            local_failure: routed.local_failure,
        })
    }

    /// 文字输入先走规则解析：能完整确定就不调用模型；否则模型补全，规则字段覆盖模型结果。
    async fn parse_with_rules(
        &self,
        content: &str,
        source: &EntrySource,
        routing: LocalRoutingRequest,
        now: DateTime<Tz>,
    ) -> Result<RoutedParseResult, CoreError> {
        let hints = match source {
            EntrySource::Ocr => RuleHints::default(),
            EntrySource::Text => {
                match rule_parser::parse_text(content, now).map_err(map_internal)? {
                    RuleOutcome::Complete(payload) => {
                        logger::info("parse.rule.complete", "model_skipped=true");
                        return Ok(RoutedParseResult {
                            payloads: vec![payload],
                            parser_source: ParserSource::Rule,
                            local_model_id: None,
                            local_failure: None,
                        });
                    }
                    RuleOutcome::NeedsModel(hints) => hints,
                }
            }
        };
        let pinned_fields = hints.prompt_block();
        let mut routed = self
            .parse_with_routing(content, source, routing, now, pinned_fields.as_deref())
            .await?;
        if !hints.is_empty() {
            let applied = hints.apply(&mut routed.payloads);
            logger::info("parse.rule.hints", format!("applied={applied}"));
            for payload in &routed.payloads {
                validate_record_payload_contract(payload).map_err(|error| {
                    CoreError::Internal(format!("规则字段与模型结果冲突：{error:#}"))
                })?;
            }
        }
        Ok(routed)
    }

    async fn parse_with_routing(
        &self,
        content: &str,
        source: &EntrySource,
        routing: LocalRoutingRequest,
        now: DateTime<Tz>,
        pinned_fields: Option<&str>,
    ) -> Result<RoutedParseResult, CoreError> {
        let system_prompt = build_record_prompt(source, pinned_fields);
        ParseRouter::route(
            routing,
            now,
            |model_id| {
                local_llm::run(local_llm::LocalLlmRequest {
                    schema_version: 1,
                    model_id: model_id.to_string(),
                    system_prompt: system_prompt.clone(),
                    user_text: content.to_string(),
                    grammar: local_llm::record_json_grammar(),
                    context_tokens: 8192,
                    max_output_tokens: 2048,
                    deadline_ms: 45_000,
                })
            },
            || self.parse_with_cloud(content, source, system_prompt.clone(), now),
        )
        .await
    }

    async fn parse_with_cloud(
        &self,
        content: &str,
        source: &EntrySource,
        system_prompt: String,
        now: DateTime<Tz>,
    ) -> Result<Vec<ParsedRecordPayload>, CoreError> {
        let llm = self
            .llm
            .as_ref()
            .ok_or_else(|| CoreError::bad_request("未配置可用的云端模型"))?;
        llm.parse_records(content.to_string(), source, system_prompt, now)
            .await
            .map_err(map_internal)
    }

    async fn upsert_asset_from_payload(
        &self,
        profile_id: &str,
        info: &ParsedAssetInfo,
    ) -> Result<AssetAck, CoreError> {
        let name = info.name.trim();
        if name.is_empty() {
            return Err(CoreError::bad_request("asset name is required"));
        }
        if info.amount <= 0.0 {
            return Err(CoreError::bad_request(
                "asset amount must be greater than 0",
            ));
        }
        let category = info
            .category
            .as_deref()
            .filter(|value| is_valid_asset_category(value))
            .ok_or_else(|| {
                CoreError::bad_request("asset category is required and must be valid")
            })?;
        let currency = validate_required_currency(info.currency.as_deref())?;
        let recorded_on = info
            .recorded_on
            .as_deref()
            .ok_or_else(|| CoreError::bad_request("asset recorded_on is required"))?;
        NaiveDate::parse_from_str(recorded_on, "%Y-%m-%d")
            .map_err(|_| CoreError::bad_request("asset recorded_on must be YYYY-MM-DD"))?;
        let asset = self
            .repo
            .find_or_create_asset(profile_id, &self.device_id, name, category, &currency)
            .await
            .map_err(map_internal)?;
        let (_snapshot, created) = self
            .repo
            .upsert_asset_snapshot(
                asset.id,
                profile_id,
                &self.device_id,
                recorded_on,
                info.amount,
                info.note.as_deref(),
            )
            .await
            .map_err(map_internal)?;
        Ok(AssetAck {
            asset_id: asset.id,
            name: asset.name,
            category: asset.category,
            amount: info.amount,
            currency: asset.currency,
            recorded_on: recorded_on.to_string(),
            created,
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
        if existing.profile_id != profile_id {
            return Err(CoreError::bad_request("draft does not belong to profile"));
        }
        if existing.status != RecordDraftStatus::Parsed {
            return Err(CoreError::bad_request("only parsed drafts can be edited"));
        }

        let payload = merge_draft_input(&existing, input)?;
        self.repo
            .update_parsed_draft_payload(draft_id, &payload)
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
        if draft.profile_id != profile_id {
            return Err(CoreError::bad_request("draft does not belong to profile"));
        }
        if draft.status != RecordDraftStatus::Parsed {
            return Err(CoreError::bad_request("draft is not confirmable"));
        }

        let action = confirmation_action_from_draft(&draft, &self.time_zone())?;
        let record = self
            .repo
            .confirm_parsed_drafts(
                profile_id,
                &self.device_id,
                vec![(draft_id, action)],
                confirmation_message(draft.kind, 1),
            )
            .await
            .map_err(map_internal)?;

        let home = self.home(profile_id).await.map_err(map_internal)?;
        Ok(SaveDraftResult { home, record })
    }

    pub async fn discard_draft(
        &self,
        profile_id: &str,
        draft_id: Uuid,
    ) -> Result<HomeSnapshot, CoreError> {
        let draft = self
            .repo
            .get_record_draft(draft_id)
            .await
            .map_err(map_internal)?;
        if draft.profile_id != profile_id {
            return Err(CoreError::bad_request("draft does not belong to profile"));
        }
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

    pub async fn confirm_all_drafts(&self, profile_id: &str) -> Result<SaveDraftResult, CoreError> {
        let drafts = self
            .repo
            .list_active_record_drafts(profile_id)
            .await
            .map_err(map_internal)?;
        if drafts.is_empty() {
            return Err(CoreError::bad_request("no active drafts to confirm"));
        }
        let time_zone = self.time_zone();
        let actions: Vec<(Uuid, ParsedDraftConfirmationAction)> = drafts
            .iter()
            .filter(|d| d.status == RecordDraftStatus::Parsed)
            .map(|draft| {
                confirmation_action_from_draft(draft, &time_zone).map(|action| (draft.id, action))
            })
            .collect::<Result<_, _>>()?;
        let last_record = self
            .repo
            .confirm_parsed_drafts(
                profile_id,
                &self.device_id,
                actions,
                &format!("已批量确认 {} 项解析结果。", drafts.len()),
            )
            .await
            .map_err(map_internal)?;
        let home = self.home(profile_id).await.map_err(map_internal)?;
        Ok(SaveDraftResult {
            home,
            record: last_record,
        })
    }

    pub async fn delete_record(&self, profile_id: &str, record_id: Uuid) -> Result<(), CoreError> {
        self.repo
            .soft_delete_record(record_id, profile_id)
            .await
            .map_err(map_internal)?;
        Ok(())
    }

    // ── Subscription management ─────────────────────────────────────

    pub async fn list_subscriptions(
        &self,
        profile_id: &str,
    ) -> Result<Vec<Subscription>, CoreError> {
        self.repo
            .list_subscriptions(profile_id)
            .await
            .map_err(map_internal)
    }

    pub async fn update_subscription(
        &self,
        profile_id: &str,
        subscription_id: Uuid,
        update: SubscriptionUpdate,
    ) -> Result<Subscription, CoreError> {
        // Validate category if provided
        if let Some(ref category) = update.category {
            let direction = update.direction.as_ref();
            validate_category_for_direction(category, direction)?;
        }
        if let Some(amount) = update.amount
            && amount <= 0.0
        {
            return Err(CoreError::bad_request("amount must be greater than 0"));
        }
        self.repo
            .update_subscription(subscription_id, profile_id, update)
            .await
            .map_err(map_internal)
    }

    pub async fn pause_subscription(
        &self,
        profile_id: &str,
        subscription_id: Uuid,
    ) -> Result<Subscription, CoreError> {
        self.repo
            .pause_subscription(subscription_id, profile_id)
            .await
            .map_err(map_internal)
    }

    pub async fn resume_subscription(
        &self,
        profile_id: &str,
        subscription_id: Uuid,
    ) -> Result<Subscription, CoreError> {
        self.repo
            .resume_subscription(subscription_id, profile_id)
            .await
            .map_err(map_internal)
    }

    pub async fn delete_subscription(
        &self,
        profile_id: &str,
        subscription_id: Uuid,
    ) -> Result<(), CoreError> {
        self.repo
            .soft_delete_subscription(subscription_id, profile_id)
            .await
            .map_err(map_internal)
    }

    // ── Asset management ────────────────────────────────────────────────

    pub async fn list_assets(
        &self,
        profile_id: &str,
    ) -> Result<Vec<AssetWithSnapshots>, CoreError> {
        self.repo
            .list_assets_with_snapshots(profile_id)
            .await
            .map_err(map_internal)
    }

    pub async fn update_asset(
        &self,
        profile_id: &str,
        asset_id: Uuid,
        update: AssetUpdateInput,
    ) -> Result<AssetWithSnapshots, CoreError> {
        // If the new name matches an existing different asset, merge into it.
        let target_id = if let Some(ref new_name) = update.name {
            let new_name = new_name.trim();
            let existing = self
                .repo
                .list_assets(profile_id)
                .await
                .map_err(map_internal)?;
            existing
                .into_iter()
                .find(|a| a.id != asset_id && a.name.trim() == new_name)
                .map(|a| a.id)
        } else {
            None
        };

        if let Some(target_id) = target_id {
            // Merge source (asset_id) into target, then return the target.
            self.repo
                .merge_asset_into(asset_id, target_id, profile_id)
                .await
                .map_err(map_internal)?;
            let assets = self
                .repo
                .list_assets_with_snapshots(profile_id)
                .await
                .map_err(map_internal)?;
            assets
                .into_iter()
                .find(|a| a.id == target_id)
                .ok_or_else(|| CoreError::Internal("merged asset not found".to_string()))
        } else {
            self.repo
                .update_asset(asset_id, profile_id, update)
                .await
                .map_err(map_internal)?;
            let assets = self
                .repo
                .list_assets_with_snapshots(profile_id)
                .await
                .map_err(map_internal)?;
            assets
                .into_iter()
                .find(|a| a.id == asset_id)
                .ok_or_else(|| CoreError::Internal("updated asset not found".to_string()))
        }
    }

    pub async fn delete_asset(&self, profile_id: &str, asset_id: Uuid) -> Result<(), CoreError> {
        self.repo
            .soft_delete_asset(asset_id, profile_id)
            .await
            .map_err(map_internal)
    }

    pub async fn delete_asset_snapshot(
        &self,
        profile_id: &str,
        snapshot_id: Uuid,
    ) -> Result<(), CoreError> {
        self.repo
            .delete_asset_snapshot(snapshot_id, profile_id)
            .await
            .map_err(map_internal)
    }

    // ── LLM config management ────────────────────────────────────────────

    pub async fn get_llm_config(&self) -> Result<Option<LlmConfig>, CoreError> {
        if let Some(json) = self
            .repo
            .get_setting("llm_config")
            .await
            .map_err(map_internal)?
        {
            let cfg = serde_json::from_str::<LlmConfig>(&json).map_err(|error| {
                CoreError::Internal(format!("stored LLM configuration is invalid: {error}"))
            })?;
            cfg.validate().map_err(map_internal)?;
            return Ok(Some(cfg));
        }
        LlmConfig::from_env_optional().map_err(map_internal)
    }

    pub async fn update_llm_config(&mut self, cfg: LlmConfig) -> Result<(), CoreError> {
        let new_client = CloudLlmClient::from_config(cfg.clone()).map_err(map_internal)?;
        let json = serde_json::to_string(&cfg).map_err(|e| CoreError::Internal(e.to_string()))?;
        self.repo
            .set_setting_with_device("llm_config", &json, &self.device_id)
            .await
            .map_err(map_internal)?;
        self.llm = Some(new_client);
        Ok(())
    }

    pub async fn list_llm_models(&self, cfg: LlmConfig) -> Result<Vec<LlmModelItem>, CoreError> {
        let client = CloudLlmClient::from_config(cfg).map_err(map_internal)?;
        client.list_models().await.map_err(map_internal)
    }

    /// Process all due subscriptions: create records for each past-due cycle.
    /// Returns the number of records created.
    pub async fn process_due_subscriptions(
        &self,
        profile_id: &str,
    ) -> Result<Vec<(String, f64, String)>, CoreError> {
        let time_zone = self.time_zone();
        let today = Utc::now().with_timezone(&time_zone).date_naive();
        let today_str = today.to_string();

        let due_subs = self
            .repo
            .list_active_due_subscriptions(profile_id, &today_str)
            .await
            .map_err(map_internal)?;

        let mut created_summaries: Vec<(String, f64, String)> = Vec::new();

        for sub in due_subs {
            let mut current_due = sub.next_due_at;

            // Generate records for each missed cycle up to today
            while current_due <= today {
                let transaction_at = time_zone
                    .with_ymd_and_hms(
                        current_due.year(),
                        current_due.month(),
                        current_due.day(),
                        9,
                        0,
                        0,
                    )
                    .earliest()
                    .ok_or_else(|| {
                        CoreError::Internal(format!(
                            "failed to construct subscription transaction time for {current_due}"
                        ))
                    })?
                    .with_timezone(&Utc);

                let record_id = subscription_charge_record_id(sub.id, current_due);
                let record_create = RecordCreate {
                    direction: sub.direction.clone(),
                    amount: sub.amount,
                    currency: sub.currency.clone(),
                    category: sub.category.clone(),
                    merchant: sub.merchant.clone(),
                    transaction_at,
                    note: sub.note.clone(),
                };

                let next =
                    advance_next_due(&sub.cycle, sub.anchor_day, sub.anchor_month, current_due);

                self.repo
                    .create_record_and_advance_subscription(
                        record_id,
                        profile_id,
                        &self.device_id,
                        record_create,
                        SubscriptionChargeAdvance {
                            subscription_id: sub.id,
                            last_charged_at: current_due,
                            next_due_at: next,
                        },
                    )
                    .await
                    .map_err(|error| {
                        CoreError::Internal(format!(
                            "failed to charge subscription {} for {}: {error}",
                            sub.id, current_due
                        ))
                    })?;

                created_summaries.push((
                    sub.merchant.clone().unwrap_or_else(|| sub.category.clone()),
                    sub.amount,
                    sub.currency.clone(),
                ));

                current_due = next;
            }
        }

        if !created_summaries.is_empty() {
            let details: Vec<String> = created_summaries
                .iter()
                .map(|(name, amount, currency)| {
                    format!(
                        "{} {}",
                        name,
                        format_amount_with_currency(*amount, Some(currency))
                    )
                })
                .collect();
            let message = format!(
                "📋 已自动记录 {} 笔订阅账单：{}",
                created_summaries.len(),
                details.join("、")
            );
            self.repo
                .create_conversation_message(
                    Uuid::new_v4(),
                    profile_id,
                    ConversationRole::Assistant,
                    &message,
                    None,
                    None,
                )
                .await
                .map_err(map_internal)?;
        }

        Ok(created_summaries)
    }

    // ── Sync API ─────────────────────────────────────────────────────────────

    pub async fn sync_list_dirty(
        &self,
        profile_id: &str,
        entity_types: &[EntityKind],
        limit: i64,
    ) -> Result<SyncDirtyBatch, CoreError> {
        let mut batch = SyncDirtyBatch::default();
        for et in entity_types {
            match et {
                EntityKind::Record => {
                    let rows = self
                        .repo
                        .list_dirty_records(profile_id, limit)
                        .await
                        .map_err(map_internal)?;
                    batch.records = rows
                        .into_iter()
                        .map(SyncDirtyItem::from_record)
                        .collect::<Result<Vec<_>>>()
                        .map_err(map_internal)?;
                }
                EntityKind::Subscription => {
                    let rows = self
                        .repo
                        .list_dirty_subscriptions(profile_id, limit)
                        .await
                        .map_err(map_internal)?;
                    batch.subscriptions = rows
                        .into_iter()
                        .map(SyncDirtyItem::from_subscription)
                        .collect::<Result<Vec<_>>>()
                        .map_err(map_internal)?;
                }
                EntityKind::Asset => {
                    let rows = self
                        .repo
                        .list_dirty_assets(profile_id, limit)
                        .await
                        .map_err(map_internal)?;
                    batch.assets = rows
                        .into_iter()
                        .map(SyncDirtyItem::from_asset)
                        .collect::<Result<Vec<_>>>()
                        .map_err(map_internal)?;
                }
                EntityKind::AssetSnapshot => {
                    let rows = self
                        .repo
                        .list_dirty_asset_snapshots(profile_id, limit)
                        .await
                        .map_err(map_internal)?;
                    batch.asset_snapshots = rows
                        .into_iter()
                        .map(SyncDirtyItem::from_asset_snapshot)
                        .collect::<Result<Vec<_>>>()
                        .map_err(map_internal)?;
                }
                EntityKind::AppSetting => {
                    let rows = self
                        .repo
                        .list_dirty_settings(limit)
                        .await
                        .map_err(map_internal)?;
                    batch.app_settings = rows
                        .into_iter()
                        .map(SyncDirtyItem::from_app_setting)
                        .collect::<Result<Vec<_>>>()
                        .map_err(map_internal)?;
                }
            }
        }
        Ok(batch)
    }

    pub async fn sync_mark_synced(
        &self,
        entries: Vec<SyncMarkSyncedEntry>,
    ) -> Result<u32, CoreError> {
        let mut records = Vec::new();
        let mut subscriptions = Vec::new();
        let mut assets = Vec::new();
        let mut asset_snapshots = Vec::new();
        let mut settings = Vec::new();

        for entry in entries {
            let id_str = &entry.id;
            match entry.entity_type {
                EntityKind::Record => {
                    let id = Uuid::parse_str(id_str)
                        .map_err(|e| CoreError::BadRequest(e.to_string()))?;
                    records.push((id, entry.synced_version));
                }
                EntityKind::Subscription => {
                    let id = Uuid::parse_str(id_str)
                        .map_err(|e| CoreError::BadRequest(e.to_string()))?;
                    subscriptions.push((id, entry.synced_version));
                }
                EntityKind::Asset => {
                    let id = Uuid::parse_str(id_str)
                        .map_err(|e| CoreError::BadRequest(e.to_string()))?;
                    assets.push((id, entry.synced_version));
                }
                EntityKind::AssetSnapshot => {
                    let id = Uuid::parse_str(id_str)
                        .map_err(|e| CoreError::BadRequest(e.to_string()))?;
                    asset_snapshots.push((id, entry.synced_version));
                }
                EntityKind::AppSetting => {
                    settings.push((id_str.to_string(), entry.synced_version));
                }
            }
        }

        let count = self
            .repo
            .mark_records_synced(&records)
            .await
            .map_err(map_internal)?
            + self
                .repo
                .mark_subscriptions_synced(&subscriptions)
                .await
                .map_err(map_internal)?
            + self
                .repo
                .mark_assets_synced(&assets)
                .await
                .map_err(map_internal)?
            + self
                .repo
                .mark_asset_snapshots_synced(&asset_snapshots)
                .await
                .map_err(map_internal)?
            + self
                .repo
                .mark_settings_synced(&settings)
                .await
                .map_err(map_internal)?;

        u32::try_from(count)
            .map_err(|_| CoreError::Internal("marked sync count overflowed u32".to_string()))
    }

    pub async fn sync_apply_remote(
        &self,
        entries: Vec<SyncRemoteEntry>,
    ) -> Result<SyncApplyResult, CoreError> {
        let mut applied = 0u32;
        let mut skipped = 0u32;
        for entry in entries {
            let did_apply = match entry.entity_type {
                EntityKind::Record => {
                    let remote: Record = serde_json::from_str(&entry.payload)
                        .map_err(|e| CoreError::BadRequest(e.to_string()))?;
                    self.repo
                        .apply_remote_record(remote)
                        .await
                        .map_err(map_internal)?
                }
                EntityKind::Subscription => {
                    let remote: Subscription = serde_json::from_str(&entry.payload)
                        .map_err(|e| CoreError::BadRequest(e.to_string()))?;
                    self.repo
                        .apply_remote_subscription(remote)
                        .await
                        .map_err(map_internal)?
                }
                EntityKind::Asset => {
                    let remote: Asset = serde_json::from_str(&entry.payload)
                        .map_err(|e| CoreError::BadRequest(e.to_string()))?;
                    self.repo
                        .apply_remote_asset(remote)
                        .await
                        .map_err(map_internal)?
                }
                EntityKind::AssetSnapshot => {
                    let remote: AssetSnapshot = serde_json::from_str(&entry.payload)
                        .map_err(|e| CoreError::BadRequest(e.to_string()))?;
                    self.repo
                        .apply_remote_asset_snapshot(remote)
                        .await
                        .map_err(map_internal)?
                }
                EntityKind::AppSetting => {
                    let remote: AppSetting = serde_json::from_str(&entry.payload)
                        .map_err(|e| CoreError::BadRequest(e.to_string()))?;
                    self.repo
                        .apply_remote_setting(remote)
                        .await
                        .map_err(map_internal)?
                }
            };
            if did_apply {
                applied += 1;
            } else {
                skipped += 1;
            }
        }
        Ok(SyncApplyResult { applied, skipped })
    }

    pub async fn sync_get_cursor(
        &self,
        profile_id: &str,
        zone: &str,
    ) -> Result<Option<String>, CoreError> {
        self.repo
            .get_sync_cursor(profile_id, zone)
            .await
            .map_err(map_internal)
    }

    pub async fn sync_set_cursor(
        &self,
        profile_id: &str,
        zone: &str,
        token: Option<&str>,
    ) -> Result<(), CoreError> {
        self.repo
            .set_sync_cursor(profile_id, zone, token)
            .await
            .map_err(map_internal)
    }

    pub async fn sync_status(&self, profile_id: &str) -> Result<SyncStatus, CoreError> {
        let pending = self
            .repo
            .pending_sync_count(profile_id)
            .await
            .map_err(map_internal)?;
        Ok(SyncStatus {
            pending_count: pending,
        })
    }

    pub async fn ledger(
        &self,
        profile_id: &str,
        preset: &str,
        start_at: Option<DateTime<FixedOffset>>,
        end_at: Option<DateTime<FixedOffset>>,
    ) -> Result<LedgerSnapshot, CoreError> {
        let time_zone = self.time_zone();
        let range = build_ledger_range(preset, start_at, end_at, &time_zone)?;
        let stats_range = RecordsStatsRange {
            start_at: range.start_at.with_timezone(&Utc),
            end_at: range.end_at.with_timezone(&Utc),
        };
        let records = self
            .repo
            .list_records(profile_id, &stats_range, None, None)
            .await
            .map_err(map_internal)?;
        let pending_sync_count = self
            .repo
            .pending_sync_count(profile_id)
            .await
            .map_err(map_internal)?;
        let currencies = collect_record_currencies(&records).map_err(map_internal)?;
        let mut rate_map = BTreeMap::new();
        let mut used_cached_rate = false;
        for currency in currencies {
            let (rate, resolution) =
                resolve_fx_rate(&self.repo, &self.fx, &currency, STATS_CURRENCY)
                    .await
                    .map_err(map_internal)?;
            rate_map.insert(currency, rate);
            used_cached_rate |= resolution.used_cached_rate;
        }
        let (summary, by_day) =
            aggregate_converted_stats(&records, stats_range.clone(), &rate_map, &time_zone)
                .map_err(map_internal)?;

        Ok(LedgerSnapshot {
            range,
            summary,
            by_day,
            pending_sync_count,
            stats_currency: STATS_CURRENCY.to_string(),
            fx_warning: used_cached_rate.then(|| "获取最新汇率失败，已使用缓存汇率".to_string()),
        })
    }
}

fn collect_record_currencies(records: &[Record]) -> Result<BTreeSet<String>> {
    let mut currencies = BTreeSet::new();
    for record in records {
        let currency = normalize_currency_code(&record.currency)
            .ok_or_else(|| anyhow!("invalid stored record currency: {}", record.currency))?;
        if currency != STATS_CURRENCY {
            currencies.insert(currency);
        }
    }
    Ok(currencies)
}

fn aggregate_converted_stats(
    records: &[Record],
    range: RecordsStatsRange,
    rate_map: &BTreeMap<String, f64>,
    time_zone: &Tz,
) -> Result<(RecordsStatsResponse, Vec<LedgerDayGroup>)> {
    let mut income_amount = 0.0;
    let mut income_count = 0;
    let mut expense_amount = 0.0;
    let mut expense_count = 0;
    let mut by_category = BTreeMap::<(String, String), (RecordDirection, f64, i64)>::new();
    let mut by_day = BTreeMap::<NaiveDate, (f64, f64, Vec<Record>)>::new();

    for record in records {
        let currency = normalize_currency_code(&record.currency)
            .ok_or_else(|| anyhow!("invalid stored record currency: {}", record.currency))?;
        let rate = if currency == STATS_CURRENCY {
            1.0
        } else {
            *rate_map
                .get(&currency)
                .ok_or_else(|| anyhow!("missing fx rate for {currency}"))?
        };
        let converted_amount = record.amount * rate;

        match record.direction {
            RecordDirection::Income => {
                income_amount += converted_amount;
                income_count += 1;
            }
            RecordDirection::Expense => {
                expense_amount += converted_amount;
                expense_count += 1;
            }
        }

        let direction_key = record.direction.as_str().to_string();
        let category_entry = by_category
            .entry((record.category.clone(), direction_key))
            .or_insert((record.direction.clone(), 0.0, 0));
        category_entry.1 += converted_amount;
        category_entry.2 += 1;

        let day = record.transaction_at.with_timezone(time_zone).date_naive();
        let day_entry = by_day.entry(day).or_insert((0.0, 0.0, Vec::new()));
        match record.direction {
            RecordDirection::Income => day_entry.0 += converted_amount,
            RecordDirection::Expense => day_entry.1 += converted_amount,
        }
        day_entry.2.push(record.clone());
    }

    let mut by_category_items = by_category
        .into_iter()
        .map(
            |((category, _), (direction, total_amount, record_count))| CategoryStatsItem {
                category,
                direction,
                total_amount,
                record_count,
            },
        )
        .collect::<Vec<_>>();
    by_category_items.sort_by(|left, right| {
        right
            .total_amount
            .partial_cmp(&left.total_amount)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.category.cmp(&right.category))
            .then_with(|| left.direction.as_str().cmp(right.direction.as_str()))
    });

    let mut by_direction = Vec::new();
    if expense_count > 0 {
        by_direction.push(DirectionStatsItem {
            direction: RecordDirection::Expense,
            total_amount: expense_amount,
            record_count: expense_count,
        });
    }
    if income_count > 0 {
        by_direction.push(DirectionStatsItem {
            direction: RecordDirection::Income,
            total_amount: income_amount,
            record_count: income_count,
        });
    }

    let by_day = by_day
        .into_iter()
        .rev()
        .map(
            |(day, (income_amount, expense_amount, records))| LedgerDayGroup {
                day,
                income_amount,
                expense_amount,
                net_amount: income_amount - expense_amount,
                records,
            },
        )
        .collect();

    Ok((
        RecordsStatsResponse {
            range,
            summary: RecordsSummary {
                income_amount,
                income_count,
                expense_amount,
                expense_count,
                net_amount: income_amount - expense_amount,
            },
            by_direction,
            by_category: by_category_items,
        },
        by_day,
    ))
}

fn build_ledger_range(
    preset: &str,
    start_at: Option<DateTime<FixedOffset>>,
    end_at: Option<DateTime<FixedOffset>>,
    time_zone: &Tz,
) -> Result<LedgerRangeSelection, CoreError> {
    let now = Utc::now().with_timezone(time_zone).fixed_offset();
    let today = now.date_naive();
    let preset = preset.trim().to_ascii_lowercase();
    let (start_at, end_at) = match preset.as_str() {
        "month" => (
            at_start_of_day(
                NaiveDate::from_ymd_opt(today.year(), today.month(), 1).unwrap(),
                time_zone,
            )?,
            now,
        ),
        "year" => (
            at_start_of_day(
                NaiveDate::from_ymd_opt(today.year(), 1, 1).unwrap(),
                time_zone,
            )?,
            now,
        ),
        "custom" => {
            let start_at =
                start_at.ok_or_else(|| CoreError::bad_request("start_at is required"))?;
            let end_at = end_at.ok_or_else(|| CoreError::bad_request("end_at is required"))?;
            if start_at > end_at {
                return Err(CoreError::bad_request(
                    "start_at must be earlier than or equal to end_at",
                ));
            }
            (start_at, end_at)
        }
        _ => {
            return Err(CoreError::bad_request(
                "preset must be month, year or custom",
            ));
        }
    };

    Ok(LedgerRangeSelection {
        preset,
        start_at,
        end_at,
    })
}

/// 当天在设备时区里的第一个有效时刻。个别时区的夏令时在 0 点切换，当天没有 00:00，
/// 此时一天从切换后的第一个整点开始。
fn at_start_of_day(date: NaiveDate, time_zone: &Tz) -> Result<DateTime<FixedOffset>, CoreError> {
    (0..24)
        .find_map(|hour| {
            time_zone
                .with_ymd_and_hms(date.year(), date.month(), date.day(), hour, 0, 0)
                .earliest()
        })
        .map(|value| value.fixed_offset())
        .ok_or_else(|| CoreError::bad_request(format!("failed to build range boundary for {date}")))
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

fn merge_draft_input(
    existing: &RecordDraft,
    input: DraftInput,
) -> Result<ParsedRecordPayload, CoreError> {
    if existing.kind == ParsedDraftKind::Asset {
        let asset = input
            .asset_info
            .ok_or_else(|| CoreError::bad_request("asset_info is required for an asset draft"))?;
        if asset.name.trim().is_empty() {
            return Err(CoreError::bad_request("asset name is required"));
        }
        if !asset.amount.is_finite() || asset.amount <= 0.0 {
            return Err(CoreError::bad_request(
                "asset amount must be a finite positive number",
            ));
        }
        if let Some(category) = asset.category.as_deref()
            && !is_valid_asset_category(category)
        {
            return Err(CoreError::bad_request("asset category is invalid"));
        }
        if let Some(currency) = asset.currency.as_deref() {
            validate_required_currency(Some(currency))?;
        }
        if let Some(recorded_on) = asset.recorded_on.as_deref() {
            NaiveDate::parse_from_str(recorded_on, "%Y-%m-%d")
                .map_err(|_| CoreError::bad_request("asset recorded_on must be YYYY-MM-DD"))?;
        }
        return Ok(ParsedRecordPayload {
            direction: None,
            amount: None,
            currency: None,
            category: None,
            merchant: None,
            transaction_at: None,
            note: None,
            subscription_cycle: None,
            asset_info: Some(asset),
        });
    }
    if input.asset_info.is_some() {
        return Err(CoreError::bad_request(
            "asset_info cannot update a record or subscription draft",
        ));
    }
    let direction = input.direction.or_else(|| existing.direction.clone());
    let amount = input.amount.or(existing.amount);
    if let Some(amount) = amount
        && amount <= 0.0
    {
        return Err(CoreError::bad_request("amount must be greater than 0"));
    }
    let category = input
        .category
        .or_else(|| existing.category.clone())
        .map(|value| validate_category_for_direction(&value, direction.as_ref()))
        .transpose()?;

    let subscription_cycle = match existing.kind {
        ParsedDraftKind::Subscription => Some(
            input
                .subscription_cycle
                .or_else(|| existing.subscription_cycle.clone())
                .ok_or_else(|| CoreError::bad_request("subscription cycle is required"))?,
        ),
        ParsedDraftKind::Record => {
            if input.subscription_cycle.is_some() {
                return Err(CoreError::bad_request(
                    "subscription_cycle cannot update a record draft",
                ));
            }
            None
        }
        ParsedDraftKind::Asset => unreachable!("asset draft returned above"),
    };

    Ok(ParsedRecordPayload {
        direction,
        amount,
        currency: normalize_optional_currency(input.currency)?
            .or_else(|| existing.currency.clone()),
        category,
        merchant: trim_optional(input.merchant).or_else(|| existing.merchant.clone()),
        transaction_at: input.transaction_at.or(existing.transaction_at),
        note: trim_optional(input.note).or_else(|| existing.note.clone()),
        subscription_cycle,
        asset_info: None,
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
        currency: validate_required_currency(payload.currency.as_deref())?,
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
    let transaction_at = payload
        .transaction_at
        .ok_or_else(|| CoreError::bad_request("parsed transaction_at is required"))?;

    Ok(RecordCreate {
        direction,
        amount,
        currency: validate_required_currency(payload.currency.as_deref())?,
        category,
        merchant: trim_optional(payload.merchant.clone()),
        transaction_at,
        note: trim_optional(payload.note.clone()),
    })
}

fn confirmation_action_from_draft(
    draft: &RecordDraft,
    time_zone: &Tz,
) -> Result<ParsedDraftConfirmationAction, CoreError> {
    match draft.kind {
        ParsedDraftKind::Record => Ok(ParsedDraftConfirmationAction::Record(
            record_create_from_draft(draft)?,
        )),
        ParsedDraftKind::Asset => {
            let info = draft
                .asset_info
                .as_ref()
                .ok_or_else(|| CoreError::bad_request("asset draft payload is missing"))?;
            let name = info.name.trim();
            if name.is_empty() {
                return Err(CoreError::bad_request("asset name is required"));
            }
            let amount = (info.amount > 0.0)
                .then_some(info.amount)
                .ok_or_else(|| CoreError::bad_request("asset amount must be greater than 0"))?;
            let category = info
                .category
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .ok_or_else(|| CoreError::bad_request("asset category is required"))?;
            if !is_valid_asset_category(category) {
                return Err(CoreError::bad_request(format!(
                    "asset category must be one of: {}",
                    ASSET_CATEGORIES.join("、")
                )));
            }
            let recorded_on = info
                .recorded_on
                .as_deref()
                .ok_or_else(|| CoreError::bad_request("asset recorded_on is required"))
                .and_then(|value| {
                    NaiveDate::parse_from_str(value, "%Y-%m-%d")
                        .map_err(|_| CoreError::bad_request("asset recorded_on must be YYYY-MM-DD"))
                })?;
            Ok(ParsedDraftConfirmationAction::Asset(
                AssetConfirmationCreate {
                    name: name.to_string(),
                    category: category.to_string(),
                    amount,
                    currency: validate_required_currency(info.currency.as_deref())?,
                    recorded_on,
                    note: trim_optional(info.note.clone()),
                },
            ))
        }
        ParsedDraftKind::Subscription => {
            let record = record_create_from_draft(draft)?;
            let cycle = draft
                .subscription_cycle
                .clone()
                .ok_or_else(|| CoreError::bad_request("subscription cycle is required"))?;
            let local_date = record.transaction_at.with_timezone(time_zone);
            let anchor_day = local_date.day() as i32;
            let anchor_month = match cycle {
                SubscriptionCycle::Yearly => Some(local_date.month() as i32),
                SubscriptionCycle::Monthly => None,
            };
            let next_due_at =
                advance_next_due(&cycle, anchor_day, anchor_month, local_date.date_naive());
            let subscription = SubscriptionCreate {
                direction: record.direction.clone(),
                amount: record.amount,
                currency: record.currency.clone(),
                category: record.category.clone(),
                merchant: record.merchant.clone(),
                note: record.note.clone(),
                cycle,
                anchor_day,
                anchor_month,
                next_due_at,
            };
            Ok(ParsedDraftConfirmationAction::Subscription {
                record,
                subscription,
            })
        }
    }
}

fn confirmation_message(kind: ParsedDraftKind, count: usize) -> &'static str {
    if count != 1 {
        return "已确认解析结果。";
    }
    match kind {
        ParsedDraftKind::Record => "账单已确认入库。",
        ParsedDraftKind::Asset => "资产已确认入库。",
        ParsedDraftKind::Subscription => "订阅已确认入库。",
    }
}

fn format_parsed_summary(payload: &ParsedRecordPayload, time_zone: &Tz) -> String {
    let direction = match payload.direction {
        Some(RecordDirection::Income) => "收入",
        Some(RecordDirection::Expense) => "支出",
        None => "未知类型",
    };
    let amount = payload
        .amount
        .map(|value| format_amount_with_currency(value, payload.currency.as_deref()))
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
        .map(|value| {
            value
                .with_timezone(time_zone)
                .format("%Y-%m-%d %H:%M:%S")
                .to_string()
        })
        .unwrap_or_else(|| "时间待确认".to_string());

    format!(
        "解析结果：{direction} {amount}，分类：{category}，商户：{merchant}，时间：{transaction_at}。"
    )
}

fn format_multi_parsed_summary(payloads: &[ParsedRecordPayload], time_zone: &Tz) -> String {
    if payloads.len() == 1 {
        return format_parsed_summary(&payloads[0], time_zone);
    }
    let lines: Vec<String> = payloads
        .iter()
        .enumerate()
        .map(|(i, p)| format!("{}. {}", i + 1, format_parsed_summary(p, time_zone)))
        .collect();
    lines.join("\n")
}

fn format_asset_amount(amount: f64, currency: &str) -> String {
    let symbol = match currency {
        "CNY" => "¥",
        "USD" => "$",
        "HKD" => "HK$",
        "EUR" => "€",
        "JPY" => "¥",
        _ => return format!("{} {:.2}", currency, amount),
    };
    if currency == "JPY" {
        format!("{}{}", symbol, amount as i64)
    } else {
        format!("{}{:.2}", symbol, amount)
    }
}

fn format_asset_acks_summary(acks: &[AssetAck]) -> String {
    if acks.is_empty() {
        return String::new();
    }
    let parts: Vec<String> = acks
        .iter()
        .map(|ack| {
            let verb = if ack.created {
                "已记录"
            } else {
                "已更新"
            };
            format!(
                "{verb} {} {} {}（{}）",
                ack.name,
                ack.category,
                format_asset_amount(ack.amount, &ack.currency),
                ack.recorded_on
            )
        })
        .collect();
    parts.join("；")
}

fn map_internal(error: anyhow::Error) -> CoreError {
    let message = format!("{error:#}");
    logger::error("core", &message);
    CoreError::Internal(message)
}

fn normalize_optional_currency(value: Option<String>) -> Result<Option<String>, CoreError> {
    match trim_optional(value) {
        Some(value) => normalize_currency_code(&value)
            .map(Some)
            .ok_or_else(|| CoreError::bad_request("invalid currency code")),
        None => Ok(None),
    }
}

fn validate_required_currency(value: Option<&str>) -> Result<String, CoreError> {
    match value.map(str::trim).filter(|value| !value.is_empty()) {
        Some(value) => normalize_currency_code(value)
            .ok_or_else(|| CoreError::bad_request("invalid currency code")),
        None => Err(CoreError::bad_request("currency is required")),
    }
}

fn subscription_charge_record_id(subscription_id: Uuid, due_at: NaiveDate) -> Uuid {
    Uuid::new_v5(&subscription_id, due_at.to_string().as_bytes())
}

fn format_amount_with_currency(amount: f64, currency: Option<&str>) -> String {
    let Some(currency) = currency.and_then(normalize_currency_code) else {
        return format!("未设置币种 {amount:.2}");
    };
    let symbol = match currency.as_str() {
        "CNY" => "¥".to_string(),
        "USD" => "$".to_string(),
        "HKD" => "HK$".to_string(),
        "EUR" => "€".to_string(),
        "JPY" => "JPY ".to_string(),
        "GBP" => "£".to_string(),
        "SGD" => "S$".to_string(),
        "AUD" => "A$".to_string(),
        "CAD" => "C$".to_string(),
        "KRW" => "₩".to_string(),
        "TWD" => "NT$".to_string(),
        "MOP" => "MOP$".to_string(),
        "THB" => "฿".to_string(),
        "MYR" => "RM".to_string(),
        other => format!("{other} "),
    };
    format!("{symbol}{amount:.2}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    const VALID_LOCAL_RESPONSE: &str = r#"[{"direction":"expense","amount":12,"currency":"CNY","category":"其他","merchant":null,"time_text":"2026-07-14 20:00","note":null,"subscription_cycle":null,"asset_info":null}]"#;

    fn test_now() -> DateTime<Tz> {
        chrono_tz::Asia::Shanghai
            .with_ymd_and_hms(2026, 7, 14, 14, 38, 45)
            .unwrap()
    }

    fn routed_payload() -> ParsedRecordPayload {
        parse_record_payloads_strict(VALID_LOCAL_RESPONSE, test_now())
            .unwrap()
            .remove(0)
    }

    fn local_error(code: local_llm::LocalLlmErrorCode) -> local_llm::LocalLlmError {
        local_llm::LocalLlmError {
            code,
            message: format!("{} failure", code.as_str()),
        }
    }

    #[test]
    fn subscription_charge_record_id_is_stable_per_due_date() {
        let subscription_id = Uuid::parse_str("b044d8a4-4bdb-497f-a0af-9a6b00db983f").unwrap();
        let first_due = NaiveDate::from_ymd_opt(2026, 7, 1).unwrap();
        let second_due = NaiveDate::from_ymd_opt(2026, 8, 1).unwrap();

        assert_eq!(
            subscription_charge_record_id(subscription_id, first_due),
            subscription_charge_record_id(subscription_id, first_due)
        );
        assert_ne!(
            subscription_charge_record_id(subscription_id, first_due),
            subscription_charge_record_id(subscription_id, second_due)
        );
    }

    #[tokio::test]
    async fn due_subscription_is_charged_once_across_repeated_checks() {
        let database_path = std::env::temp_dir().join(format!(
            "billlens-subscription-maintenance-{}.sqlite",
            Uuid::new_v4()
        ));
        let repo = BillRepository::connect(&database_path).await.unwrap();
        let profile_id = "subscription-test";
        let subscription_id = Uuid::new_v4();
        let today = Utc::now()
            .with_timezone(&chrono_tz::Asia::Shanghai)
            .date_naive();
        repo.create_subscription(
            subscription_id,
            profile_id,
            "test-device",
            SubscriptionCreate {
                direction: RecordDirection::Expense,
                amount: 12.0,
                currency: "CNY".to_string(),
                category: "订阅".to_string(),
                merchant: Some("测试订阅".to_string()),
                note: None,
                cycle: SubscriptionCycle::Yearly,
                anchor_day: today.day() as i32,
                anchor_month: Some(today.month() as i32),
                next_due_at: today,
            },
        )
        .await
        .unwrap();
        let service = AppService::new(
            repo.clone(),
            EngineBootstrap {
                device_id: "test-device".to_string(),
                llm: None,
                log_file_path: None,
                time_zone: "Asia/Shanghai".to_string(),
            },
        )
        .unwrap();

        let first = service.process_due_subscriptions(profile_id).await.unwrap();
        let second = service.process_due_subscriptions(profile_id).await.unwrap();

        assert_eq!(first.len(), 1);
        assert!(second.is_empty());
    }

    #[tokio::test]
    async fn rule_parsed_text_creates_draft_without_any_model() {
        let db_path = std::env::temp_dir().join(format!("billlens-rule-{}.sqlite", Uuid::new_v4()));
        let repo = BillRepository::connect(&db_path).await.unwrap();
        let service = AppService::new(
            repo,
            EngineBootstrap {
                device_id: "test-device".to_string(),
                llm: None,
                log_file_path: None,
                time_zone: "Asia/Shanghai".to_string(),
            },
        )
        .unwrap();
        let profile_id = "rule-profile";
        service.bootstrap(profile_id).await.unwrap();

        // 未配置任何模型、云端模式：规则能完整解析时不应调用模型。
        let result = service
            .submit_text(
                profile_id,
                "今天早上打车花了100元".to_string(),
                false,
                EntrySource::Text,
                LocalRoutingRequest {
                    mode: LocalRoutingMode::CloudOnly,
                    model_id: None,
                },
            )
            .await
            .unwrap();

        assert_eq!(result.parser_source, ParserSource::Rule);
        let draft = &result.home.drafts[0];
        assert_eq!(draft.parser_source, ParserSource::Rule);
        assert_eq!(draft.amount, Some(100.0));
        assert_eq!(draft.category.as_deref(), Some("交通"));
        let beijing = FixedOffset::east_opt(8 * 3600).unwrap();
        let local = draft.transaction_at.unwrap().with_timezone(&beijing);
        assert_eq!(
            local.date_naive(),
            Utc::now().with_timezone(&beijing).date_naive()
        );
        assert_eq!(local.format("%H:%M:%S").to_string(), "08:00:00");
        // 回复消息中的时间必须按设备时区显示，而不是 UTC。
        let expected = format!("时间：{} 08:00:00", local.format("%Y-%m-%d"));
        assert!(
            result
                .home
                .messages
                .iter()
                .any(|message| message.content.contains(&expected)),
            "missing {expected}"
        );

        // 规则不完整时仍需要模型；未配置模型时显式报错，而不是静默生成残缺草稿。
        let error = service
            .submit_text(
                profile_id,
                "在全家花了25".to_string(),
                false,
                EntrySource::Text,
                LocalRoutingRequest {
                    mode: LocalRoutingMode::CloudOnly,
                    model_id: None,
                },
            )
            .await
            .unwrap_err();
        assert!(error.to_string().contains("未配置可用的云端模型"));
    }

    #[test]
    fn parsed_summary_formats_time_in_device_offset() {
        let payload = ParsedRecordPayload {
            direction: Some(RecordDirection::Expense),
            amount: Some(9.9),
            currency: Some("CNY".to_string()),
            category: Some("餐饮".to_string()),
            merchant: Some("瑞幸咖啡".to_string()),
            transaction_at: Some(
                DateTime::parse_from_rfc3339("2026-10-22T08:02:01Z")
                    .unwrap()
                    .with_timezone(&Utc),
            ),
            note: None,
            subscription_cycle: None,
            asset_info: None,
        };
        assert!(
            format_parsed_summary(&payload, &chrono_tz::Asia::Shanghai)
                .contains("时间：2026-10-22 16:02:01")
        );
    }

    #[tokio::test]
    async fn cloud_only_calls_cloud_once_and_never_calls_local() {
        let local_calls = AtomicUsize::new(0);
        let cloud_calls = AtomicUsize::new(0);
        let result = ParseRouter::route(
            LocalRoutingRequest {
                mode: LocalRoutingMode::CloudOnly,
                model_id: Some("ignored-model".to_string()),
            },
            test_now(),
            |_| {
                local_calls.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Err(local_error(
                    local_llm::LocalLlmErrorCode::InferenceFailed,
                )))
            },
            || {
                cloud_calls.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Ok(vec![routed_payload()]))
            },
        )
        .await
        .unwrap();

        assert_eq!(local_calls.load(Ordering::SeqCst), 0);
        assert_eq!(cloud_calls.load(Ordering::SeqCst), 1);
        assert_eq!(result.parser_source, ParserSource::Cloud);
    }

    #[tokio::test]
    async fn valid_local_contract_never_calls_cloud() {
        let local_calls = AtomicUsize::new(0);
        let cloud_calls = AtomicUsize::new(0);
        let result = ParseRouter::route(
            LocalRoutingRequest {
                mode: LocalRoutingMode::LocalFirst,
                model_id: Some("test-model".to_string()),
            },
            test_now(),
            |_| {
                local_calls.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Ok((
                    VALID_LOCAL_RESPONSE.to_string(),
                    "test-model".to_string(),
                    10,
                )))
            },
            || {
                cloud_calls.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Ok(vec![routed_payload()]))
            },
        )
        .await
        .unwrap();

        assert_eq!(local_calls.load(Ordering::SeqCst), 1);
        assert_eq!(cloud_calls.load(Ordering::SeqCst), 0);
        assert_eq!(result.parser_source, ParserSource::Local);
    }

    #[tokio::test]
    async fn allowed_local_failure_calls_cloud_exactly_once() {
        let cloud_calls = AtomicUsize::new(0);
        let result = ParseRouter::route(
            LocalRoutingRequest {
                mode: LocalRoutingMode::LocalFirst,
                model_id: Some("test-model".to_string()),
            },
            test_now(),
            |_| std::future::ready(Err(local_error(local_llm::LocalLlmErrorCode::OutOfMemory))),
            || {
                cloud_calls.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Ok(vec![routed_payload()]))
            },
        )
        .await
        .unwrap();

        assert_eq!(cloud_calls.load(Ordering::SeqCst), 1);
        assert_eq!(result.parser_source, ParserSource::CloudAfterLocalFailure);
        assert_eq!(result.local_failure.unwrap().code, "out_of_memory");
    }

    #[tokio::test]
    async fn invalid_local_output_contract_calls_cloud_exactly_once() {
        let cloud_calls = AtomicUsize::new(0);
        let result = ParseRouter::route(
            LocalRoutingRequest {
                mode: LocalRoutingMode::LocalFirst,
                model_id: Some("test-model".to_string()),
            },
            test_now(),
            |_| {
                std::future::ready(Ok((
                    "```json\n[]\n```".to_string(),
                    "test-model".to_string(),
                    10,
                )))
            },
            || {
                cloud_calls.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Ok(vec![routed_payload()]))
            },
        )
        .await
        .unwrap();

        assert_eq!(cloud_calls.load(Ordering::SeqCst), 1);
        let local_failure = result.local_failure.unwrap();
        assert_eq!(local_failure.code, "output_contract_failed");
        assert!(
            local_failure
                .message
                .contains("expected value at line 1 column 1")
        );
    }

    #[test]
    fn local_output_failure_log_preserves_the_complete_raw_response() {
        let raw_content = "[\n  {\"category\":\"模型自定义分类\"}\n]";

        assert_eq!(
            local_output_log_message("test-model", raw_content),
            format!("model_id=test-model content={raw_content}")
        );
    }

    #[tokio::test]
    async fn cancellation_does_not_call_cloud() {
        let cloud_calls = AtomicUsize::new(0);
        let error = ParseRouter::route(
            LocalRoutingRequest {
                mode: LocalRoutingMode::LocalFirst,
                model_id: Some("test-model".to_string()),
            },
            test_now(),
            |_| std::future::ready(Err(local_error(local_llm::LocalLlmErrorCode::Cancelled))),
            || {
                cloud_calls.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Ok(vec![routed_payload()]))
            },
        )
        .await
        .unwrap_err();

        assert_eq!(cloud_calls.load(Ordering::SeqCst), 0);
        assert!(error.to_string().contains("cancelled"));
    }

    #[tokio::test]
    async fn local_and_cloud_failures_are_both_preserved() {
        let cloud_calls = AtomicUsize::new(0);
        let error = ParseRouter::route(
            LocalRoutingRequest {
                mode: LocalRoutingMode::LocalFirst,
                model_id: Some("test-model".to_string()),
            },
            test_now(),
            |_| std::future::ready(Err(local_error(local_llm::LocalLlmErrorCode::Timeout))),
            || {
                cloud_calls.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Err(CoreError::Internal("cloud failed".to_string())))
            },
        )
        .await
        .unwrap_err();

        assert_eq!(cloud_calls.load(Ordering::SeqCst), 1);
        assert!(error.to_string().contains("timeout failure"));
        assert!(error.to_string().contains("cloud failed"));
    }

    #[test]
    fn build_custom_range_rejects_inverted_range() {
        let shanghai = chrono_tz::Asia::Shanghai;
        let start = shanghai
            .with_ymd_and_hms(2026, 4, 2, 0, 0, 0)
            .unwrap()
            .fixed_offset();
        let end = shanghai
            .with_ymd_and_hms(2026, 4, 1, 0, 0, 0)
            .unwrap()
            .fixed_offset();
        let error = build_ledger_range("custom", Some(start), Some(end), &shanghai).unwrap_err();
        assert_eq!(
            error.to_string(),
            "start_at must be earlier than or equal to end_at"
        );
    }

    #[test]
    fn aggregate_converted_stats_converts_mixed_currency_records() {
        let range = RecordsStatsRange {
            start_at: Utc::now(),
            end_at: Utc::now(),
        };
        let transaction_at = Utc::now();
        let records = vec![
            Record {
                id: Uuid::new_v4(),
                profile_id: "local-default".to_string(),
                direction: RecordDirection::Expense,
                amount: 10.0,
                currency: "USD".to_string(),
                category: "交通".to_string(),
                merchant: None,
                transaction_at,
                note: None,
                device_id: "device-a".to_string(),
                sync_version: 1,
                synced_version: 1,
                deleted_at: None,
                created_at: transaction_at,
                updated_at: transaction_at,
            },
            Record {
                id: Uuid::new_v4(),
                profile_id: "local-default".to_string(),
                direction: RecordDirection::Income,
                amount: 20.0,
                currency: "CNY".to_string(),
                category: "其他".to_string(),
                merchant: None,
                transaction_at,
                note: None,
                device_id: "device-a".to_string(),
                sync_version: 1,
                synced_version: 1,
                deleted_at: None,
                created_at: transaction_at,
                updated_at: transaction_at,
            },
        ];
        let rate_map = BTreeMap::from([(String::from("USD"), 7.0)]);

        let (stats, by_day) =
            aggregate_converted_stats(&records, range, &rate_map, &chrono_tz::Asia::Shanghai)
                .unwrap();

        assert_eq!(stats.summary.expense_amount, 70.0);
        assert_eq!(stats.summary.income_amount, 20.0);
        assert_eq!(stats.summary.net_amount, -50.0);
        assert_eq!(by_day.len(), 1);
        assert_eq!(by_day[0].expense_amount, 70.0);
        assert_eq!(by_day[0].income_amount, 20.0);
    }

    #[test]
    fn ledger_groups_records_by_local_date_in_device_time_zone() {
        // 2026-10-22 02:00 UTC：上海是 10-22 10:00，纽约是 10-21 22:00。
        let transaction_at = DateTime::parse_from_rfc3339("2026-10-22T02:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let record = Record {
            id: Uuid::new_v4(),
            profile_id: "local-default".to_string(),
            direction: RecordDirection::Expense,
            amount: 30.0,
            currency: "CNY".to_string(),
            category: "交通".to_string(),
            merchant: None,
            transaction_at,
            note: None,
            device_id: "device-a".to_string(),
            sync_version: 1,
            synced_version: 1,
            deleted_at: None,
            created_at: transaction_at,
            updated_at: transaction_at,
        };
        let range = RecordsStatsRange {
            start_at: transaction_at,
            end_at: transaction_at,
        };
        let day_in = |time_zone: &Tz| {
            aggregate_converted_stats(
                std::slice::from_ref(&record),
                range.clone(),
                &BTreeMap::new(),
                time_zone,
            )
            .unwrap()
            .1[0]
                .day
        };
        assert_eq!(
            day_in(&chrono_tz::Asia::Shanghai),
            NaiveDate::from_ymd_opt(2026, 10, 22).unwrap()
        );
        assert_eq!(
            day_in(&chrono_tz::America::New_York),
            NaiveDate::from_ymd_opt(2026, 10, 21).unwrap()
        );
    }

    #[test]
    fn start_of_day_uses_first_valid_local_time() {
        let shanghai = at_start_of_day(
            NaiveDate::from_ymd_opt(2026, 10, 1).unwrap(),
            &chrono_tz::Asia::Shanghai,
        )
        .unwrap();
        assert_eq!(shanghai.to_rfc3339(), "2026-10-01T00:00:00+08:00");

        // 智利 2026-09-06 夏令时在 0 点开始，当天没有 00:00。
        let santiago = at_start_of_day(
            NaiveDate::from_ymd_opt(2026, 9, 6).unwrap(),
            &chrono_tz::America::Santiago,
        )
        .unwrap();
        assert_eq!(santiago.to_rfc3339(), "2026-09-06T01:00:00-03:00");
    }

    #[test]
    fn invalid_time_zone_names_are_rejected() {
        assert!(parse_time_zone("Asia/Shanghai").is_ok());
        assert!(parse_time_zone("UTC+8").is_err());
        assert!(parse_time_zone("").is_err());
    }
}
