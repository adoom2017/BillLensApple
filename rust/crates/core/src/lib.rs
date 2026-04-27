mod fx;
mod llm;
mod logger;
pub mod stt;

use anyhow::{Result, anyhow};
pub use billlens_apple_db::{
    ALL_RECORD_CATEGORIES, ASSET_CATEGORIES, AppSetting, Asset, AssetAck, AssetSnapshot,
    AssetUpdateInput, AssetWithSnapshots, BillRepository, CategoryStatsItem, ConversationMessage,
    ConversationRole, DirectionStatsItem, EXPENSE_CATEGORIES, EntityKind, INCOME_CATEGORIES,
    ParsedAssetInfo, ParsedRecordPayload, Record, RecordCreate, RecordDirection, RecordDraft,
    RecordDraftStatus, RecordDraftUpdate, RecordsStatsRange, RecordsStatsResponse, RecordsSummary,
    Subscription, SubscriptionCreate, SubscriptionCycle, SubscriptionUpdate, advance_next_due,
    is_valid_asset_category, is_valid_record_category, is_valid_record_category_for_direction,
};
use chrono::{DateTime, Datelike, FixedOffset, NaiveDate, TimeZone, Utc};
use fx::{FxClient, resolve_fx_rate};
pub use llm::{LlmConfig, LlmModelItem};
use llm::{LlmClient, clean_asset_name, normalize_currency_code};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
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
    llm: Option<LlmClient>,
    fx: FxClient,
}

impl AppService {
    pub fn new(repo: BillRepository, bootstrap: EngineBootstrap) -> Result<Self> {
        logger::initialize(bootstrap.log_file_path.as_deref())?;
        let llm = bootstrap.llm.map(LlmClient::from_config).transpose()?;
        Ok(Self {
            repo,
            device_id: bootstrap.device_id,
            llm,
            fx: FxClient::new(),
        })
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
    ) -> Result<SubmitTextResult, CoreError> {
        let content = trim_required(content, "content is required")?;
        let sanitized_content = if content.len() > 80 {
            format!(
                "{}…({}字符)",
                &content[..content.floor_char_boundary(80)],
                content.chars().count()
            )
        } else {
            content.clone()
        };
        logger::info(
            "submit_text",
            format!("source={source:?} auto_confirm={auto_confirm} content={sanitized_content}"),
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
        // P1: both text and OCR go through the multi-parser so the array-format
        // prompt is decoded correctly regardless of source. Text keeps the raw
        // input as a note fallback; OCR skips it (cleaner output).
        let payloads = match source {
            EntrySource::Text => llm.parse_record_text_multi(content.clone()).await,
            EntrySource::Ocr => llm.parse_record_ocr_text_multi(content.clone()).await,
        }
        .map_err(map_internal)?;

        // P2: treat an empty parse result as a failure rather than silent success.
        if payloads.is_empty() {
            return Err(CoreError::bad_request(
                "未能从输入中识别出任何账单记录，请检查图片或文字内容后重试。",
            ));
        }

        logger::info(
            "submit_text",
            format!(
                "parsed_payloads={}",
                serde_json::to_string(&payloads)
                    .unwrap_or_else(|_| "<serialize failed>".to_string())
            ),
        );

        // Process asset payloads first; they do not become bills or subscriptions.
        let mut asset_acks: Vec<AssetAck> = Vec::new();
        let mut bill_payloads: Vec<ParsedRecordPayload> = Vec::with_capacity(payloads.len());
        for payload in payloads.iter() {
            if let Some(ref asset_info) = payload.asset_info {
                match self.upsert_asset_from_payload(profile_id, asset_info).await {
                    Ok(ack) => {
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
                    }
                    Err(e) => {
                        logger::error("submit_text.asset", e.to_string());
                    }
                }
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
            });
        }

        let summary = format_multi_parsed_summary(&bill_payloads);
        let asset_tail = if asset_acks.is_empty() {
            String::new()
        } else {
            format!("\n{}", format_asset_acks_summary(&asset_acks))
        };

        // Create subscriptions for any payload with subscription_cycle detected
        let mut subscription_created = false;
        for payload in &bill_payloads {
            if let Some(ref cycle) = payload.subscription_cycle {
                if let (Some(direction), Some(amount), Some(currency)) =
                    (&payload.direction, payload.amount, &payload.currency)
                {
                    let now = Utc::now().with_timezone(&shanghai_offset());
                    let today = now.date_naive();
                    let anchor_day = payload
                        .transaction_at
                        .map(|t| t.with_timezone(&shanghai_offset()).day() as i32)
                        .unwrap_or(today.day() as i32);
                    let anchor_month = match cycle {
                        SubscriptionCycle::Yearly => Some(
                            payload
                                .transaction_at
                                .map(|t| t.with_timezone(&shanghai_offset()).month() as i32)
                                .unwrap_or(today.month() as i32),
                        ),
                        SubscriptionCycle::Monthly => None,
                    };
                    let next_due = advance_next_due(cycle, anchor_day, anchor_month, today);
                    let sub_create = SubscriptionCreate {
                        direction: direction.clone(),
                        amount,
                        currency: currency.clone(),
                        category: payload
                            .category
                            .clone()
                            .unwrap_or_else(|| "订阅".to_string()),
                        merchant: payload.merchant.clone(),
                        note: payload.note.clone(),
                        cycle: cycle.clone(),
                        anchor_day,
                        anchor_month,
                        next_due_at: next_due,
                    };
                    if let Err(e) = self
                        .repo
                        .create_subscription(
                            Uuid::new_v4(),
                            profile_id,
                            &self.device_id,
                            sub_create,
                        )
                        .await
                    {
                        logger::error("submit_text.subscription", e.to_string());
                    } else {
                        subscription_created = true;
                        logger::info(
                            "submit_text.subscription",
                            format!("created subscription cycle={}", cycle.as_str()),
                        );
                    }
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
            });
        }

        // Draft path — insert all rows atomically via the batch method.
        let drafts = self
            .repo
            .create_record_drafts_batch(profile_id, &content, &bill_payloads)
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
        })
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
            .clone()
            .filter(|c| is_valid_asset_category(c))
            .unwrap_or_else(|| "存款".to_string());
        let currency = info.currency.clone().unwrap_or_else(|| "CNY".to_string());
        let recorded_on = match info.recorded_on.as_deref() {
            Some(day) if NaiveDate::parse_from_str(day, "%Y-%m-%d").is_ok() => day.to_string(),
            _ => Utc::now()
                .with_timezone(&shanghai_offset())
                .date_naive()
                .format("%Y-%m-%d")
                .to_string(),
        };
        // Try to match an existing asset whose cleaned name equals the incoming cleaned name,
        // so "东方财富股票账号" and "东方财富" are treated as the same asset.
        let existing_assets = self
            .repo
            .list_assets(profile_id)
            .await
            .map_err(map_internal)?;
        let matched = existing_assets
            .into_iter()
            .find(|a| clean_asset_name(&a.name) == name);
        let asset = if let Some(existing) = matched {
            existing
        } else {
            self.repo
                .find_or_create_asset(profile_id, &self.device_id, name, &category, &currency)
                .await
                .map_err(map_internal)?
        };
        let (_snapshot, created) = self
            .repo
            .upsert_asset_snapshot(
                asset.id,
                profile_id,
                &self.device_id,
                &recorded_on,
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
            recorded_on,
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
        // Validate all drafts before any DB write so a single bad draft
        // cannot leave earlier ones committed.  The batch method is transactional.
        let creates: Vec<(Uuid, RecordCreate)> = drafts
            .iter()
            .filter(|d| d.status == RecordDraftStatus::Parsed)
            .map(|d| record_create_from_draft(d).map(|c| (d.id, c)))
            .collect::<Result<_, _>>()?;
        let last_record = self
            .repo
            .confirm_record_drafts_batch(profile_id, &self.device_id, creates)
            .await
            .map_err(map_internal)?;
        self.repo
            .create_conversation_message(
                Uuid::new_v4(),
                profile_id,
                ConversationRole::Assistant,
                &format!("已批量确认 {} 笔账单入库。", drafts.len()),
                None,
                last_record.as_ref().map(|r| r.id),
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
        if let Some(amount) = update.amount {
            if amount <= 0.0 {
                return Err(CoreError::bad_request("amount must be greater than 0"));
            }
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

    pub async fn get_llm_config(&self) -> Result<LlmConfig, CoreError> {
        if let Some(json) = self
            .repo
            .get_setting("llm_config")
            .await
            .map_err(map_internal)?
        {
            if let Ok(cfg) = serde_json::from_str::<LlmConfig>(&json) {
                return Ok(cfg);
            }
        }
        Ok(LlmConfig::from_env_optional()
            .map_err(map_internal)?
            .unwrap())
    }

    pub async fn update_llm_config(&mut self, cfg: LlmConfig) -> Result<(), CoreError> {
        let new_client = LlmClient::from_config(cfg.clone()).map_err(map_internal)?;
        let json = serde_json::to_string(&cfg).map_err(|e| CoreError::Internal(e.to_string()))?;
        self.repo
            .set_setting_with_device("llm_config", &json, &self.device_id)
            .await
            .map_err(map_internal)?;
        self.llm = Some(new_client);
        Ok(())
    }

    pub async fn list_llm_models(&self, cfg: LlmConfig) -> Result<Vec<LlmModelItem>, CoreError> {
        let client = LlmClient::from_config(cfg).map_err(map_internal)?;
        client.list_models().await.map_err(map_internal)
    }

    /// Process all due subscriptions: create records for each past-due cycle.
    /// Returns the number of records created.
    pub async fn process_due_subscriptions(
        &self,
        profile_id: &str,
    ) -> Result<Vec<(String, f64, String)>, CoreError> {
        let now = Utc::now().with_timezone(&shanghai_offset());
        let today = now.date_naive();
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
                let transaction_at = shanghai_offset()
                    .with_ymd_and_hms(
                        current_due.year(),
                        current_due.month(),
                        current_due.day(),
                        9,
                        0,
                        0,
                    )
                    .single()
                    .unwrap_or_else(|| Utc::now().with_timezone(&shanghai_offset()))
                    .with_timezone(&Utc);

                let record_id = Uuid::new_v4();
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

                if let Err(e) = self
                    .repo
                    .create_record_and_advance_subscription(
                        record_id,
                        profile_id,
                        &self.device_id,
                        record_create,
                        sub.id,
                        current_due,
                        next,
                    )
                    .await
                {
                    logger::error(
                        "subscription.charge",
                        format!("failed to charge subscription {}: {e}", sub.id),
                    );
                    break;
                }

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
                        .map(|r| SyncDirtyItem::from_record(r))
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
                        .map(|s| SyncDirtyItem::from_subscription(s))
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
                        .map(|a| SyncDirtyItem::from_asset(a))
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
                        .map(|s| SyncDirtyItem::from_asset_snapshot(s))
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
                        .map(|s| SyncDirtyItem::from_app_setting(s))
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
        let (summary, by_day) = aggregate_converted_stats(&records, stats_range.clone(), &rate_map)
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

        let day = record
            .transaction_at
            .with_timezone(&shanghai_offset())
            .date_naive();
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
) -> Result<LedgerRangeSelection, CoreError> {
    let now = Utc::now().with_timezone(&shanghai_offset());
    let today = now.date_naive();
    let preset = preset.trim().to_ascii_lowercase();
    let (start_at, end_at) = match preset.as_str() {
        "month" => (
            at_start_of_day(NaiveDate::from_ymd_opt(today.year(), today.month(), 1).unwrap())?,
            now,
        ),
        "year" => (
            at_start_of_day(NaiveDate::from_ymd_opt(today.year(), 1, 1).unwrap())?,
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

fn merge_draft_input(
    existing: &RecordDraft,
    input: DraftInput,
) -> Result<RecordDraftUpdate, CoreError> {
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
        currency: normalize_optional_currency(input.currency)?
            .or_else(|| existing.currency.clone()),
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
        currency: validate_or_default_currency(payload.currency.as_deref())?,
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
        currency: validate_or_default_currency(payload.currency.as_deref())?,
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
        .map(|value| value.format("%Y-%m-%d %H:%M:%S").to_string())
        .unwrap_or_else(|| "时间待确认".to_string());

    format!(
        "解析结果：{direction} {amount}，分类：{category}，商户：{merchant}，时间：{transaction_at}。"
    )
}

fn format_multi_parsed_summary(payloads: &[ParsedRecordPayload]) -> String {
    if payloads.len() == 1 {
        return format_parsed_summary(&payloads[0]);
    }
    let lines: Vec<String> = payloads
        .iter()
        .enumerate()
        .map(|(i, p)| format!("{}. {}", i + 1, format_parsed_summary(p)))
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
    logger::error("core", error.to_string());
    CoreError::Internal(error.to_string())
}

fn normalize_optional_currency(value: Option<String>) -> Result<Option<String>, CoreError> {
    match trim_optional(value) {
        Some(value) => normalize_currency_code(&value)
            .map(Some)
            .ok_or_else(|| CoreError::bad_request("invalid currency code")),
        None => Ok(None),
    }
}

fn validate_or_default_currency(value: Option<&str>) -> Result<String, CoreError> {
    match value.map(str::trim).filter(|value| !value.is_empty()) {
        Some(value) => normalize_currency_code(value)
            .ok_or_else(|| CoreError::bad_request("invalid currency code")),
        None => Ok("CNY".to_string()),
    }
}

fn format_amount_with_currency(amount: f64, currency: Option<&str>) -> String {
    let currency = currency
        .and_then(normalize_currency_code)
        .unwrap_or_else(|| "CNY".to_string());
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

    #[test]
    fn build_custom_range_rejects_inverted_range() {
        let start = shanghai_offset()
            .with_ymd_and_hms(2026, 4, 2, 0, 0, 0)
            .unwrap();
        let end = shanghai_offset()
            .with_ymd_and_hms(2026, 4, 1, 0, 0, 0)
            .unwrap();
        let error = build_ledger_range("custom", Some(start), Some(end)).unwrap_err();
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

        let (stats, by_day) = aggregate_converted_stats(&records, range, &rate_map).unwrap();

        assert_eq!(stats.summary.expense_amount, 70.0);
        assert_eq!(stats.summary.income_amount, 20.0);
        assert_eq!(stats.summary.net_amount, -50.0);
        assert_eq!(by_day.len(), 1);
        assert_eq!(by_day[0].expense_amount, 70.0);
        assert_eq!(by_day[0].income_amount, 20.0);
    }
}
