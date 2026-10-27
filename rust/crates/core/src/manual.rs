//! 手动结构化新增与编辑：账单、订阅、资产（含更新估值）。
//!
//! 校验与写入语义复用草稿确认：`validated_record_create` / `validated_asset_create`
//! 与 `BillRepository::create_manual_entry`（同一个按动作写入的事务函数）。手动操作不写对话消息。

use crate::{
    AppService, CoreError, ParsedAssetInfo, ParsedDraftConfirmationAction, Record, RecordDirection,
    Subscription, SubscriptionCreate, SubscriptionCycle, logger, map_internal,
    validated_asset_create, validated_record_create,
};
use billlens_apple_db::RecordUpdate;
use chrono::{DateTime, Datelike, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManualRecordInput {
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
pub struct ManualSubscriptionInput {
    pub direction: RecordDirection,
    pub amount: f64,
    pub currency: String,
    pub category: String,
    pub merchant: Option<String>,
    pub note: Option<String>,
    pub cycle: SubscriptionCycle,
    /// 首次扣费日（设备时区的本地日期，YYYY-MM-DD）。
    pub first_charge_on: NaiveDate,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManualSubscriptionResult {
    pub subscription: Subscription,
    /// 首次扣费日不晚于今天时立即生成的账单笔数（含补扣）。
    pub charged: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManualAssetResult {
    pub asset_id: Uuid,
    pub asset_snapshot_id: Option<Uuid>,
}

impl AppService {
    pub async fn create_manual_record(
        &self,
        profile_id: &str,
        input: ManualRecordInput,
    ) -> Result<Record, CoreError> {
        let create = validated_record_create(
            input.direction,
            Some(input.amount),
            Some(&input.currency),
            Some(&input.category),
            input.merchant,
            input.transaction_at,
            input.note,
        )?;
        let (_, record) = self
            .repo
            .create_manual_entry(
                profile_id,
                &self.device_id,
                ParsedDraftConfirmationAction::Record(create),
            )
            .await
            .map_err(map_internal)?;
        let record =
            record.ok_or_else(|| CoreError::Internal("manual record was not created".into()))?;
        logger::info("manual.record.create", record.id.to_string());
        Ok(record)
    }

    pub async fn update_record(
        &self,
        profile_id: &str,
        record_id: Uuid,
        input: ManualRecordInput,
    ) -> Result<Record, CoreError> {
        let create = validated_record_create(
            input.direction,
            Some(input.amount),
            Some(&input.currency),
            Some(&input.category),
            input.merchant,
            input.transaction_at,
            input.note,
        )?;
        let record = self
            .repo
            .update_record(
                record_id,
                profile_id,
                &self.device_id,
                RecordUpdate {
                    direction: create.direction,
                    amount: create.amount,
                    currency: create.currency,
                    category: create.category,
                    merchant: create.merchant,
                    transaction_at: create.transaction_at,
                    note: create.note,
                },
            )
            .await
            .map_err(map_internal)?;
        logger::info("manual.record.update", record.id.to_string());
        Ok(record)
    }

    /// 首次扣费日即订阅的第一个到期日；不晚于今天时立即对该订阅补扣到今天，
    /// 账单 ID 与自动补扣相同（订阅 ID + 到期日），重复执行不会多扣。
    pub async fn create_manual_subscription(
        &self,
        profile_id: &str,
        input: ManualSubscriptionInput,
    ) -> Result<ManualSubscriptionResult, CoreError> {
        let time_zone = self.time_zone();
        // 只借用账单字段校验；订阅本身不存时刻，扣费时刻由补扣逻辑决定。
        let first_charge_at = input
            .first_charge_on
            .and_hms_opt(0, 0, 0)
            .expect("midnight is valid")
            .and_utc();
        let validated = validated_record_create(
            input.direction,
            Some(input.amount),
            Some(&input.currency),
            Some(&input.category),
            input.merchant,
            first_charge_at,
            input.note,
        )?;
        let first_on = input.first_charge_on;
        let anchor_day = first_on.day() as i32;
        let anchor_month = match input.cycle {
            SubscriptionCycle::Yearly => Some(first_on.month() as i32),
            SubscriptionCycle::Monthly => None,
        };
        let subscription = self
            .repo
            .create_subscription(
                Uuid::new_v4(),
                profile_id,
                &self.device_id,
                SubscriptionCreate {
                    direction: validated.direction,
                    amount: validated.amount,
                    currency: validated.currency,
                    category: validated.category,
                    merchant: validated.merchant,
                    note: validated.note,
                    cycle: input.cycle,
                    anchor_day,
                    anchor_month,
                    next_due_at: first_on,
                },
            )
            .await
            .map_err(map_internal)?;

        let today = Utc::now().with_timezone(&time_zone).date_naive();
        let charged = if first_on <= today {
            // 订阅已提交；每期扣费各自原子，失败的期数由下次到期维护按相同 ID 补上。
            // 错误文案明确订阅已存在，避免用户重试时重复新增。
            self.charge_subscription_through(profile_id, &subscription, today, time_zone)
                .await
                .map_err(|error| {
                    CoreError::Internal(format!(
                        "subscription {} was created, but charging it failed (remaining cycles will be retried by due-subscription maintenance): {error}",
                        subscription.id
                    ))
                })?
                .len()
        } else {
            0
        };
        let subscription = self
            .repo
            .get_subscription(subscription.id, profile_id)
            .await
            .map_err(map_internal)?;
        logger::info(
            "manual.subscription.create",
            format!("id={} charged={charged}", subscription.id),
        );
        Ok(ManualSubscriptionResult {
            subscription,
            charged,
        })
    }

    /// 新增资产与「更新估值」共用：同名资产合并，同日快照覆盖（与草稿确认一致）。
    pub async fn create_manual_asset(
        &self,
        profile_id: &str,
        input: ParsedAssetInfo,
    ) -> Result<ManualAssetResult, CoreError> {
        let create = validated_asset_create(&input)?;
        let (confirmation, _) = self
            .repo
            .create_manual_entry(
                profile_id,
                &self.device_id,
                ParsedDraftConfirmationAction::Asset(create),
            )
            .await
            .map_err(map_internal)?;
        let asset_id = confirmation
            .asset_id
            .ok_or_else(|| CoreError::Internal("manual asset was not created".into()))?;
        logger::info("manual.asset.upsert", asset_id.to_string());
        Ok(ManualAssetResult {
            asset_id,
            asset_snapshot_id: confirmation.asset_snapshot_id,
        })
    }
}

#[cfg(test)]
mod tests;
