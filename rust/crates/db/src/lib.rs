mod models;

use anyhow::{Context, Result, anyhow};
use chrono::{DateTime, NaiveDate, Utc};
pub use models::*;
use sqlx::{
    FromRow, QueryBuilder, Row, Sqlite, SqlitePool,
    sqlite::{SqliteConnectOptions, SqlitePoolOptions, SqliteRow},
};
use std::path::Path;
use uuid::Uuid;

#[derive(Clone)]
pub struct BillRepository {
    pool: SqlitePool,
}

impl BillRepository {
    pub async fn connect(database_path: impl AsRef<Path>) -> Result<Self> {
        let connect_options = SqliteConnectOptions::new()
            .filename(database_path)
            .create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(4)
            .connect_with(connect_options)
            .await
            .context("failed to open sqlite database")?;
        sqlx::migrate!("../../migrations")
            .run(&pool)
            .await
            .context("failed to run database migrations")?;
        Ok(Self { pool })
    }

    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    pub async fn create_record(
        &self,
        id: Uuid,
        profile_id: &str,
        device_id: &str,
        input: RecordCreate,
    ) -> Result<Record> {
        let row = sqlx::query_as::<_, RecordRow>(
            r#"
            INSERT INTO records (
                id, profile_id, direction, amount, currency, category, merchant, transaction_at, note, device_id
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            RETURNING *
            "#,
        )
        .bind(id.to_string())
        .bind(profile_id)
        .bind(input.direction.as_str())
        .bind(input.amount)
        .bind(input.currency)
        .bind(input.category)
        .bind(input.merchant)
        .bind(input.transaction_at)
        .bind(input.note)
        .bind(device_id)
        .fetch_one(&self.pool)
        .await
        .context("failed to insert record")?;

        row.try_into()
    }

    pub async fn update_record(
        &self,
        id: Uuid,
        profile_id: &str,
        input: RecordUpdate,
    ) -> Result<Record> {
        let row = sqlx::query_as::<_, RecordRow>(
            r#"
            UPDATE records
            SET direction = ?3,
                amount = ?4,
                currency = ?5,
                category = ?6,
                merchant = ?7,
                transaction_at = ?8,
                note = ?9,
                sync_version = sync_version + 1,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = ?1 AND profile_id = ?2 AND deleted_at IS NULL
            RETURNING *
            "#,
        )
        .bind(id.to_string())
        .bind(profile_id)
        .bind(input.direction.as_str())
        .bind(input.amount)
        .bind(input.currency)
        .bind(input.category)
        .bind(input.merchant)
        .bind(input.transaction_at)
        .bind(input.note)
        .fetch_optional(&self.pool)
        .await
        .context("failed to update record")?
        .ok_or_else(|| anyhow!("record not found"))?;

        row.try_into()
    }

    pub async fn soft_delete_record(&self, id: Uuid, profile_id: &str) -> Result<Record> {
        let row = sqlx::query_as::<_, RecordRow>(
            r#"
            UPDATE records
            SET deleted_at = CURRENT_TIMESTAMP,
                sync_version = sync_version + 1,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = ?1 AND profile_id = ?2 AND deleted_at IS NULL
            RETURNING *
            "#,
        )
        .bind(id.to_string())
        .bind(profile_id)
        .fetch_optional(&self.pool)
        .await
        .context("failed to delete record")?
        .ok_or_else(|| anyhow!("record not found"))?;

        row.try_into()
    }

    pub async fn get_record(&self, id: Uuid, profile_id: &str) -> Result<Record> {
        let row = sqlx::query_as::<_, RecordRow>(
            "SELECT * FROM records WHERE id = ?1 AND profile_id = ?2 AND deleted_at IS NULL",
        )
        .bind(id.to_string())
        .bind(profile_id)
        .fetch_optional(&self.pool)
        .await
        .context("failed to load record")?
        .ok_or_else(|| anyhow!("record not found"))?;

        row.try_into()
    }

    pub async fn get_record_draft(&self, id: Uuid) -> Result<RecordDraft> {
        let row = sqlx::query_as::<_, RecordDraftRow>("SELECT * FROM parsed_drafts WHERE id = ?1")
            .bind(id.to_string())
            .fetch_optional(&self.pool)
            .await
            .context("failed to load parsed draft")?
            .ok_or_else(|| anyhow!("parsed draft not found"))?;

        row.try_into()
    }

    pub async fn update_parsed_draft_payload(
        &self,
        id: Uuid,
        payload: &ParsedRecordPayload,
    ) -> Result<RecordDraft> {
        let existing = self.get_record_draft(id).await?;
        if existing.status != RecordDraftStatus::Parsed {
            return Err(anyhow!("only parsed drafts can be updated"));
        }
        let kind = parsed_draft_kind(payload)?;
        if existing.kind != kind {
            return Err(anyhow!("parsed draft kind cannot be changed"));
        }
        let payload_json =
            serde_json::to_string(payload).context("failed to encode updated draft payload")?;
        let row = sqlx::query_as::<_, RecordDraftRow>(
            r#"
            UPDATE parsed_drafts
            SET payload_json = ?2,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = ?1 AND status = 'parsed'
            RETURNING *
            "#,
        )
        .bind(id.to_string())
        .bind(payload_json)
        .fetch_one(&self.pool)
        .await
        .context("failed to update parsed draft")?;

        row.try_into()
    }

    pub async fn list_active_record_drafts(&self, profile_id: &str) -> Result<Vec<RecordDraft>> {
        let rows = sqlx::query_as::<_, RecordDraftRow>(
            r#"
            SELECT * FROM parsed_drafts
            WHERE profile_id = ?1 AND status = 'parsed'
            ORDER BY created_at ASC, rowid ASC
            "#,
        )
        .bind(profile_id)
        .fetch_all(&self.pool)
        .await
        .context("failed to list active parsed drafts")?;

        rows.into_iter().map(TryInto::try_into).collect()
    }

    pub async fn create_parsed_drafts_batch(
        &self,
        profile_id: &str,
        content: &str,
        payloads: &[ParsedRecordPayload],
        parser_source: ParserSource,
        fallback_reason: Option<&str>,
    ) -> Result<Vec<RecordDraft>> {
        if payloads.is_empty() {
            return Err(anyhow!("cannot create an empty parsed draft batch"));
        }
        let mut tx = self
            .pool
            .begin()
            .await
            .context("failed to begin draft batch transaction")?;
        let batch_id = Uuid::new_v4();
        let mut drafts = Vec::with_capacity(payloads.len());
        for parsed in payloads {
            let id = Uuid::new_v4();
            let kind = parsed_draft_kind(parsed)?;
            let payload_json =
                serde_json::to_string(parsed).context("failed to encode parsed draft payload")?;
            let row = sqlx::query_as::<_, RecordDraftRow>(
                r#"
                INSERT INTO parsed_drafts (
                    id, batch_id, profile_id, kind, parser_source, original_content,
                    payload_json, fallback_reason, status
                )
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'parsed')
                RETURNING *
                "#,
            )
            .bind(id.to_string())
            .bind(batch_id.to_string())
            .bind(profile_id)
            .bind(kind.as_str())
            .bind(parser_source.as_str())
            .bind(content)
            .bind(payload_json)
            .bind(fallback_reason)
            .fetch_one(&mut *tx)
            .await
            .context("failed to insert parsed draft in batch")?;
            drafts.push(row.try_into()?);
        }
        tx.commit()
            .await
            .context("failed to commit draft batch transaction")?;
        Ok(drafts)
    }

    pub async fn confirm_parsed_drafts(
        &self,
        profile_id: &str,
        device_id: &str,
        actions: Vec<(Uuid, ParsedDraftConfirmationAction)>,
        assistant_message: &str,
    ) -> Result<Option<Record>> {
        if actions.is_empty() {
            return Err(anyhow!("no parsed drafts supplied for confirmation"));
        }
        let mut tx = self
            .pool
            .begin()
            .await
            .context("failed to begin parsed draft confirmation transaction")?;
        let mut last_record: Option<Record> = None;
        let single_draft_id = (actions.len() == 1).then(|| actions[0].0);

        for (draft_id, action) in actions {
            let draft_row = sqlx::query_as::<_, RecordDraftRow>(
                "SELECT * FROM parsed_drafts WHERE id = ?1 AND profile_id = ?2",
            )
            .bind(draft_id.to_string())
            .bind(profile_id)
            .fetch_optional(&mut *tx)
            .await
            .context("failed to load parsed draft for confirmation")?
            .ok_or_else(|| anyhow!("parsed draft not found for profile"))?;
            let draft: RecordDraft = draft_row.try_into()?;
            if draft.status != RecordDraftStatus::Parsed {
                return Err(anyhow!("parsed draft is not confirmable"));
            }
            if draft.kind != action.kind() {
                return Err(anyhow!(
                    "parsed draft kind does not match confirmation action"
                ));
            }

            let confirmation = match action {
                ParsedDraftConfirmationAction::Record(create) => {
                    let record =
                        insert_record_in_transaction(&mut tx, profile_id, device_id, create)
                            .await?;
                    let confirmation = ParsedDraftConfirmation {
                        record_id: Some(record.id),
                        ..Default::default()
                    };
                    last_record = Some(record);
                    confirmation
                }
                ParsedDraftConfirmationAction::Asset(create) => {
                    confirm_asset_in_transaction(&mut tx, profile_id, device_id, create).await?
                }
                ParsedDraftConfirmationAction::Subscription {
                    record,
                    subscription,
                } => {
                    let subscription_id = Uuid::new_v4();
                    sqlx::query(
                        r#"
                        INSERT INTO subscriptions (
                            id, profile_id, direction, amount, currency, category,
                            merchant, note, cycle, anchor_day, anchor_month,
                            next_due_at, device_id
                        )
                        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                        "#,
                    )
                    .bind(subscription_id.to_string())
                    .bind(profile_id)
                    .bind(subscription.direction.as_str())
                    .bind(subscription.amount)
                    .bind(subscription.currency)
                    .bind(subscription.category)
                    .bind(subscription.merchant)
                    .bind(subscription.note)
                    .bind(subscription.cycle.as_str())
                    .bind(subscription.anchor_day)
                    .bind(subscription.anchor_month)
                    .bind(subscription.next_due_at.to_string())
                    .bind(device_id)
                    .execute(&mut *tx)
                    .await
                    .context("failed to insert subscription while confirming parsed draft")?;

                    let created_record =
                        insert_record_in_transaction(&mut tx, profile_id, device_id, record)
                            .await?;
                    let confirmation = ParsedDraftConfirmation {
                        record_id: Some(created_record.id),
                        subscription_id: Some(subscription_id),
                        ..Default::default()
                    };
                    last_record = Some(created_record);
                    confirmation
                }
            };

            let confirmation_json = serde_json::to_string(&confirmation)
                .context("failed to encode parsed draft confirmation")?;
            let result = sqlx::query(
                r#"
                UPDATE parsed_drafts
                SET status = 'confirmed', confirmation_json = ?2,
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = ?1 AND profile_id = ?3 AND status = 'parsed'
                "#,
            )
            .bind(draft_id.to_string())
            .bind(confirmation_json)
            .bind(profile_id)
            .execute(&mut *tx)
            .await
            .context("failed to mark parsed draft confirmed")?;
            if result.rows_affected() != 1 {
                return Err(anyhow!(
                    "parsed draft confirmation state changed concurrently"
                ));
            }
        }

        sqlx::query(
            r#"
            INSERT INTO conversation_messages (
                id, profile_id, role, content, draft_id, record_id
            )
            VALUES (?1, ?2, 'assistant', ?3, ?4, ?5)
            "#,
        )
        .bind(Uuid::new_v4().to_string())
        .bind(profile_id)
        .bind(assistant_message)
        .bind(single_draft_id.map(|id| id.to_string()))
        .bind(last_record.as_ref().map(|record| record.id.to_string()))
        .execute(&mut *tx)
        .await
        .context("failed to insert confirmation conversation message")?;

        tx.commit()
            .await
            .context("failed to commit parsed draft confirmation transaction")?;
        Ok(last_record)
    }

    pub async fn latest_record(&self, profile_id: &str) -> Result<Option<Record>> {
        let row = sqlx::query_as::<_, RecordRow>(
            r#"
            SELECT * FROM records
            WHERE profile_id = ?1 AND deleted_at IS NULL
            ORDER BY updated_at DESC
            LIMIT 1
            "#,
        )
        .bind(profile_id)
        .fetch_optional(&self.pool)
        .await
        .context("failed to load latest record")?;

        row.map(TryInto::try_into).transpose()
    }

    pub async fn discard_record_draft(&self, draft_id: Uuid) -> Result<RecordDraft> {
        let row = sqlx::query_as::<_, RecordDraftRow>(
            r#"
            UPDATE parsed_drafts
            SET status = 'discarded',
                updated_at = CURRENT_TIMESTAMP
            WHERE id = ?1 AND status = 'parsed'
            RETURNING *
            "#,
        )
        .bind(draft_id.to_string())
        .fetch_one(&self.pool)
        .await
        .context("failed to discard record draft")?;

        row.try_into()
    }

    pub async fn create_conversation_message(
        &self,
        id: Uuid,
        profile_id: &str,
        role: ConversationRole,
        content: &str,
        draft_id: Option<Uuid>,
        record_id: Option<Uuid>,
    ) -> Result<ConversationMessage> {
        let row = sqlx::query_as::<_, ConversationMessageRow>(
            r#"
            INSERT INTO conversation_messages (
                id, profile_id, role, content, draft_id, record_id
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            RETURNING *
            "#,
        )
        .bind(id.to_string())
        .bind(profile_id)
        .bind(role.as_str())
        .bind(content)
        .bind(draft_id.map(|value| value.to_string()))
        .bind(record_id.map(|value| value.to_string()))
        .fetch_one(&self.pool)
        .await
        .context("failed to insert conversation message")?;

        row.try_into()
    }

    pub async fn list_conversation_messages(
        &self,
        profile_id: &str,
        limit: i64,
    ) -> Result<Vec<ConversationMessage>> {
        let rows = sqlx::query_as::<_, ConversationMessageRow>(
            r#"
            SELECT * FROM conversation_messages
            WHERE profile_id = ?1
            ORDER BY created_at DESC
            LIMIT ?2
            "#,
        )
        .bind(profile_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .context("failed to load conversation messages")?;

        let mut messages: Vec<ConversationMessage> = rows
            .into_iter()
            .map(TryInto::try_into)
            .collect::<Result<Vec<_>>>()?;
        messages.reverse();
        Ok(messages)
    }

    pub async fn list_records(
        &self,
        profile_id: &str,
        range: &RecordsStatsRange,
        direction: Option<RecordDirection>,
        category: Option<&str>,
    ) -> Result<Vec<Record>> {
        let mut builder = QueryBuilder::<Sqlite>::new("SELECT * FROM records WHERE profile_id = ");
        builder
            .push_bind(profile_id)
            .push(" AND deleted_at IS NULL AND transaction_at >= ")
            .push_bind(range.start_at)
            .push(" AND transaction_at <= ")
            .push_bind(range.end_at);

        if let Some(direction) = direction {
            builder
                .push(" AND direction = ")
                .push_bind(direction.as_str());
        }
        if let Some(category) = category {
            builder.push(" AND category = ").push_bind(category);
        }
        builder.push(" ORDER BY transaction_at DESC, created_at DESC");

        let rows = builder
            .build_query_as::<RecordRow>()
            .fetch_all(&self.pool)
            .await
            .context("failed to load records")?;

        rows.into_iter().map(TryInto::try_into).collect()
    }

    // ── Statement import ────────────────────────────────────────────────

    /// 返回 `ids` 中已存在于 records 的 ID（包括软删除），用于账单导入幂等判断。
    pub async fn find_existing_record_ids(&self, ids: &[Uuid]) -> Result<Vec<Uuid>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let mut builder = QueryBuilder::<Sqlite>::new("SELECT id FROM records WHERE id IN (");
        let mut separated = builder.separated(", ");
        for id in ids {
            separated.push_bind(id.to_string());
        }
        builder.push(")");
        let rows = builder
            .build()
            .fetch_all(&self.pool)
            .await
            .context("failed to look up existing record ids")?;
        rows.into_iter()
            .map(|row| {
                let id: String = row.try_get("id")?;
                Uuid::parse_str(&id).with_context(|| format!("invalid record id {id}"))
            })
            .collect()
    }

    /// 在单个事务中写入账单导入记录与助手消息。已存在的 ID（含软删除，或另一台设备
    /// 同步先到达）跳过不覆盖；任一写入失败整体回滚。
    pub async fn import_statement_records(
        &self,
        profile_id: &str,
        device_id: &str,
        records: Vec<(Uuid, RecordCreate)>,
        assistant_message: impl FnOnce(usize, usize) -> String,
    ) -> Result<StatementImportCounts> {
        let mut tx = self
            .pool
            .begin()
            .await
            .context("failed to begin statement import transaction")?;

        let total = records.len();
        let mut inserted = 0;
        for (id, create) in records {
            let result = sqlx::query(
                r#"
                INSERT INTO records (
                    id, profile_id, direction, amount, currency, category,
                    merchant, transaction_at, note, device_id
                )
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                ON CONFLICT (id) DO NOTHING
                "#,
            )
            .bind(id.to_string())
            .bind(profile_id)
            .bind(create.direction.as_str())
            .bind(create.amount)
            .bind(&create.currency)
            .bind(&create.category)
            .bind(&create.merchant)
            .bind(create.transaction_at)
            .bind(&create.note)
            .bind(device_id)
            .execute(&mut *tx)
            .await
            .context("failed to insert statement record")?;
            inserted += result.rows_affected() as usize;
        }
        let skipped_existing = total - inserted;

        sqlx::query(
            r#"
            INSERT INTO conversation_messages (id, profile_id, role, content, draft_id, record_id)
            VALUES (?1, ?2, ?3, ?4, NULL, NULL)
            "#,
        )
        .bind(Uuid::new_v4().to_string())
        .bind(profile_id)
        .bind(ConversationRole::Assistant.as_str())
        .bind(assistant_message(inserted, skipped_existing))
        .execute(&mut *tx)
        .await
        .context("failed to insert statement import message")?;

        tx.commit()
            .await
            .context("failed to commit statement import transaction")?;
        Ok(StatementImportCounts {
            inserted,
            skipped_existing,
        })
    }

    // ── Subscription operations ─────────────────────────────────────────

    pub async fn create_subscription(
        &self,
        id: Uuid,
        profile_id: &str,
        device_id: &str,
        input: SubscriptionCreate,
    ) -> Result<Subscription> {
        let row = sqlx::query_as::<_, SubscriptionRow>(
            r#"
            INSERT INTO subscriptions (
                id, profile_id, direction, amount, currency, category, merchant, note,
                cycle, anchor_day, anchor_month, next_due_at, device_id
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
            RETURNING *
            "#,
        )
        .bind(id.to_string())
        .bind(profile_id)
        .bind(input.direction.as_str())
        .bind(input.amount)
        .bind(&input.currency)
        .bind(&input.category)
        .bind(&input.merchant)
        .bind(&input.note)
        .bind(input.cycle.as_str())
        .bind(input.anchor_day)
        .bind(input.anchor_month)
        .bind(input.next_due_at.to_string())
        .bind(device_id)
        .fetch_one(&self.pool)
        .await
        .context("failed to insert subscription")?;

        row.try_into()
    }

    pub async fn update_subscription(
        &self,
        id: Uuid,
        profile_id: &str,
        update: SubscriptionUpdate,
    ) -> Result<Subscription> {
        let existing = self.get_subscription(id, profile_id).await?;

        let direction = update.direction.unwrap_or(existing.direction);
        let amount = update.amount.unwrap_or(existing.amount);
        let currency = update.currency.unwrap_or(existing.currency);
        let category = update.category.unwrap_or(existing.category);
        let merchant = update.merchant.or(existing.merchant);
        let note = update.note.or(existing.note);
        let cycle = update.cycle.unwrap_or(existing.cycle);
        let anchor_day = update.anchor_day.unwrap_or(existing.anchor_day);
        let anchor_month = update.anchor_month.or(existing.anchor_month);

        let row = sqlx::query_as::<_, SubscriptionRow>(
            r#"
            UPDATE subscriptions
            SET direction = ?3, amount = ?4, currency = ?5, category = ?6,
                merchant = ?7, note = ?8, cycle = ?9, anchor_day = ?10,
                anchor_month = ?11,
                sync_version = sync_version + 1,
                updated_at = datetime('now')
            WHERE id = ?1 AND profile_id = ?2 AND deleted_at IS NULL
            RETURNING *
            "#,
        )
        .bind(id.to_string())
        .bind(profile_id)
        .bind(direction.as_str())
        .bind(amount)
        .bind(&currency)
        .bind(&category)
        .bind(&merchant)
        .bind(&note)
        .bind(cycle.as_str())
        .bind(anchor_day)
        .bind(anchor_month)
        .fetch_optional(&self.pool)
        .await
        .context("failed to update subscription")?
        .ok_or_else(|| anyhow!("subscription not found"))?;

        row.try_into()
    }

    pub async fn get_subscription(&self, id: Uuid, profile_id: &str) -> Result<Subscription> {
        let row = sqlx::query_as::<_, SubscriptionRow>(
            "SELECT * FROM subscriptions WHERE id = ?1 AND profile_id = ?2 AND deleted_at IS NULL",
        )
        .bind(id.to_string())
        .bind(profile_id)
        .fetch_optional(&self.pool)
        .await
        .context("failed to load subscription")?
        .ok_or_else(|| anyhow!("subscription not found"))?;

        row.try_into()
    }

    pub async fn list_subscriptions(&self, profile_id: &str) -> Result<Vec<Subscription>> {
        let rows = sqlx::query_as::<_, SubscriptionRow>(
            r#"
            SELECT * FROM subscriptions
            WHERE profile_id = ?1 AND deleted_at IS NULL
            ORDER BY is_active DESC, created_at DESC
            "#,
        )
        .bind(profile_id)
        .fetch_all(&self.pool)
        .await
        .context("failed to list subscriptions")?;

        rows.into_iter().map(TryInto::try_into).collect()
    }

    pub async fn list_active_due_subscriptions(
        &self,
        profile_id: &str,
        today: &str,
    ) -> Result<Vec<Subscription>> {
        let rows = sqlx::query_as::<_, SubscriptionRow>(
            r#"
            SELECT * FROM subscriptions
            WHERE profile_id = ?1 AND is_active = 1 AND deleted_at IS NULL
              AND next_due_at <= ?2
            ORDER BY next_due_at ASC
            "#,
        )
        .bind(profile_id)
        .bind(today)
        .fetch_all(&self.pool)
        .await
        .context("failed to list active due subscriptions")?;

        rows.into_iter().map(TryInto::try_into).collect()
    }

    /// Atomically create a record and update the subscription's charged state.
    /// Prevents duplicate records if the app crashes mid-cycle.
    pub async fn create_record_and_advance_subscription(
        &self,
        record_id: Uuid,
        profile_id: &str,
        device_id: &str,
        input: RecordCreate,
        advance: SubscriptionChargeAdvance,
    ) -> Result<Record> {
        let mut tx = self
            .pool
            .begin()
            .await
            .context("failed to begin subscription charge transaction")?;

        let row = sqlx::query_as::<_, RecordRow>(
            r#"
            INSERT INTO records (
                id, profile_id, direction, amount, currency, category, merchant, transaction_at, note, device_id
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            RETURNING *
            "#,
        )
        .bind(record_id.to_string())
        .bind(profile_id)
        .bind(input.direction.as_str())
        .bind(input.amount)
        .bind(&input.currency)
        .bind(&input.category)
        .bind(&input.merchant)
        .bind(input.transaction_at)
        .bind(&input.note)
        .bind(device_id)
        .fetch_one(&mut *tx)
        .await
        .context("failed to insert record in subscription charge")?;

        sqlx::query(
            r#"
            UPDATE subscriptions
            SET last_charged_at = ?2, next_due_at = ?3, updated_at = datetime('now'),
                sync_version = sync_version + 1, device_id = ?4
            WHERE id = ?1
            "#,
        )
        .bind(advance.subscription_id.to_string())
        .bind(advance.last_charged_at.to_string())
        .bind(advance.next_due_at.to_string())
        .bind(device_id)
        .execute(&mut *tx)
        .await
        .context("failed to advance subscription in charge")?;

        tx.commit()
            .await
            .context("failed to commit subscription charge transaction")?;

        row.try_into()
    }

    pub async fn pause_subscription(&self, id: Uuid, profile_id: &str) -> Result<Subscription> {
        let row = sqlx::query_as::<_, SubscriptionRow>(
            r#"
            UPDATE subscriptions
            SET is_active = 0, sync_version = sync_version + 1, updated_at = datetime('now')
            WHERE id = ?1 AND profile_id = ?2 AND deleted_at IS NULL
            RETURNING *
            "#,
        )
        .bind(id.to_string())
        .bind(profile_id)
        .fetch_optional(&self.pool)
        .await
        .context("failed to pause subscription")?
        .ok_or_else(|| anyhow!("subscription not found"))?;

        row.try_into()
    }

    pub async fn resume_subscription(&self, id: Uuid, profile_id: &str) -> Result<Subscription> {
        let row = sqlx::query_as::<_, SubscriptionRow>(
            r#"
            UPDATE subscriptions
            SET is_active = 1, sync_version = sync_version + 1, updated_at = datetime('now')
            WHERE id = ?1 AND profile_id = ?2 AND deleted_at IS NULL
            RETURNING *
            "#,
        )
        .bind(id.to_string())
        .bind(profile_id)
        .fetch_optional(&self.pool)
        .await
        .context("failed to resume subscription")?
        .ok_or_else(|| anyhow!("subscription not found"))?;

        row.try_into()
    }

    pub async fn soft_delete_subscription(&self, id: Uuid, profile_id: &str) -> Result<()> {
        let row = sqlx::query_as::<_, SubscriptionRow>(
            r#"
            UPDATE subscriptions
            SET deleted_at = datetime('now'), is_active = 0,
                sync_version = sync_version + 1, updated_at = datetime('now')
            WHERE id = ?1 AND profile_id = ?2 AND deleted_at IS NULL
            RETURNING *
            "#,
        )
        .bind(id.to_string())
        .bind(profile_id)
        .fetch_optional(&self.pool)
        .await
        .context("failed to delete subscription")?
        .ok_or_else(|| anyhow!("subscription not found"))?;

        let _: Subscription = row.try_into()?;
        Ok(())
    }

    // ── Asset operations ────────────────────────────────────────────────

    pub async fn list_assets(&self, profile_id: &str) -> Result<Vec<Asset>> {
        let rows = sqlx::query_as::<_, AssetRow>(
            r#"SELECT * FROM assets WHERE profile_id = ?1 AND deleted_at IS NULL"#,
        )
        .bind(profile_id)
        .fetch_all(&self.pool)
        .await
        .context("failed to list assets")?;
        rows.into_iter().map(Asset::try_from).collect()
    }

    pub async fn find_or_create_asset(
        &self,
        profile_id: &str,
        device_id: &str,
        name: &str,
        category: &str,
        currency: &str,
    ) -> Result<Asset> {
        let id = Uuid::new_v4();
        // Atomic upsert: on conflict with the partial unique index
        // (profile_id, name) WHERE deleted_at IS NULL, touch updated_at so
        // RETURNING always gives us the live row regardless of which branch ran.
        let row = sqlx::query_as::<_, AssetRow>(
            r#"
            INSERT INTO assets (id, profile_id, name, category, currency, device_id)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT (profile_id, name) WHERE deleted_at IS NULL
            DO UPDATE SET updated_at = updated_at
            RETURNING *
            "#,
        )
        .bind(id.to_string())
        .bind(profile_id)
        .bind(name)
        .bind(category)
        .bind(currency)
        .bind(device_id)
        .fetch_one(&self.pool)
        .await
        .context("failed to upsert asset")?;
        row.try_into()
    }

    /// Returns (snapshot, was_created). Same-day re-record overwrites amount and note.
    pub async fn upsert_asset_snapshot(
        &self,
        asset_id: Uuid,
        profile_id: &str,
        device_id: &str,
        recorded_on: &str,
        amount: f64,
        note: Option<&str>,
    ) -> Result<(AssetSnapshot, bool)> {
        let existing = sqlx::query_as::<_, AssetSnapshotRow>(
            r#"
            SELECT * FROM asset_snapshots
            WHERE asset_id = ?1 AND recorded_on = ?2 AND deleted_at IS NULL
            "#,
        )
        .bind(asset_id.to_string())
        .bind(recorded_on)
        .fetch_optional(&self.pool)
        .await
        .context("failed to lookup asset snapshot")?;

        let created = existing.is_none();
        let row = if let Some(prev) = existing {
            sqlx::query_as::<_, AssetSnapshotRow>(
                r#"
                UPDATE asset_snapshots
                SET amount = ?2, note = ?3,
                    sync_version = sync_version + 1,
                    updated_at = datetime('now')
                WHERE id = ?1
                RETURNING *
                "#,
            )
            .bind(prev.id)
            .bind(amount)
            .bind(note)
            .fetch_one(&self.pool)
            .await
            .context("failed to update asset snapshot")?
        } else {
            let id = Uuid::new_v4();
            sqlx::query_as::<_, AssetSnapshotRow>(
                r#"
                INSERT INTO asset_snapshots (id, asset_id, profile_id, amount, recorded_on, note, device_id)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                RETURNING *
                "#,
            )
            .bind(id.to_string())
            .bind(asset_id.to_string())
            .bind(profile_id)
            .bind(amount)
            .bind(recorded_on)
            .bind(note)
            .bind(device_id)
            .fetch_one(&self.pool)
            .await
            .context("failed to insert asset snapshot")?
        };

        sqlx::query(
            "UPDATE assets SET sync_version = sync_version + 1, updated_at = datetime('now') WHERE id = ?1",
        )
        .bind(asset_id.to_string())
        .execute(&self.pool)
        .await
        .context("failed to touch asset updated_at")?;

        let snap: AssetSnapshot = row.try_into()?;
        Ok((snap, created))
    }

    pub async fn list_assets_with_snapshots(
        &self,
        profile_id: &str,
    ) -> Result<Vec<AssetWithSnapshots>> {
        let asset_rows = sqlx::query_as::<_, AssetRow>(
            r#"
            SELECT * FROM assets
            WHERE profile_id = ?1 AND deleted_at IS NULL
            ORDER BY updated_at DESC
            "#,
        )
        .bind(profile_id)
        .fetch_all(&self.pool)
        .await
        .context("failed to list assets")?;

        let mut results = Vec::with_capacity(asset_rows.len());
        for row in asset_rows {
            let asset: Asset = row.try_into()?;
            let snap_rows = sqlx::query_as::<_, AssetSnapshotRow>(
                r#"
                SELECT * FROM asset_snapshots
                WHERE asset_id = ?1 AND deleted_at IS NULL
                ORDER BY recorded_on ASC
                "#,
            )
            .bind(asset.id.to_string())
            .fetch_all(&self.pool)
            .await
            .context("failed to list asset snapshots")?;

            let snapshots: Vec<AssetSnapshot> = snap_rows
                .into_iter()
                .map(TryInto::try_into)
                .collect::<Result<_>>()?;

            let latest = snapshots.last();
            let latest_amount = latest.map(|s| s.amount);
            let latest_recorded_on = latest.map(|s| s.recorded_on.clone());

            results.push(AssetWithSnapshots {
                id: asset.id,
                profile_id: asset.profile_id,
                name: asset.name,
                category: asset.category,
                currency: asset.currency,
                note: asset.note,
                snapshots,
                latest_amount,
                latest_recorded_on,
                created_at: asset.created_at,
                updated_at: asset.updated_at,
            });
        }

        results.sort_by_key(|item| std::cmp::Reverse(item.updated_at));
        Ok(results)
    }

    pub async fn update_asset(
        &self,
        id: Uuid,
        profile_id: &str,
        update: AssetUpdateInput,
    ) -> Result<Asset> {
        let existing = sqlx::query_as::<_, AssetRow>(
            "SELECT * FROM assets WHERE id = ?1 AND profile_id = ?2 AND deleted_at IS NULL",
        )
        .bind(id.to_string())
        .bind(profile_id)
        .fetch_optional(&self.pool)
        .await
        .context("failed to load asset")?
        .ok_or_else(|| anyhow!("asset not found"))?;

        let name = update.name.unwrap_or(existing.name);
        let category = update.category.unwrap_or(existing.category);
        let currency = update.currency.unwrap_or(existing.currency);
        let note = update.note.or(existing.note);

        let row = sqlx::query_as::<_, AssetRow>(
            r#"
            UPDATE assets
            SET name = ?3, category = ?4, currency = ?5, note = ?6,
                sync_version = sync_version + 1, updated_at = datetime('now')
            WHERE id = ?1 AND profile_id = ?2 AND deleted_at IS NULL
            RETURNING *
            "#,
        )
        .bind(id.to_string())
        .bind(profile_id)
        .bind(&name)
        .bind(&category)
        .bind(&currency)
        .bind(&note)
        .fetch_optional(&self.pool)
        .await
        .context("failed to update asset")?
        .ok_or_else(|| anyhow!("asset not found"))?;

        row.try_into()
    }

    /// Merge snapshots atomically, retaining the target row identity on date conflicts.
    pub async fn merge_asset_into(
        &self,
        source_id: Uuid,
        target_id: Uuid,
        profile_id: &str,
    ) -> Result<()> {
        if source_id == target_id {
            return Err(anyhow!("cannot merge an asset into itself"));
        }
        let source = source_id.to_string();
        let target = target_id.to_string();
        let mut tx = self
            .pool
            .begin()
            .await
            .context("failed to begin asset merge")?;
        let mut currencies = Vec::new();
        for id in [&source, &target] {
            let asset = sqlx::query_as::<_, AssetRow>(
                "SELECT * FROM assets WHERE id = ?1 AND profile_id = ?2 AND deleted_at IS NULL",
            )
            .bind(id)
            .bind(profile_id)
            .fetch_optional(&mut *tx)
            .await
            .context("failed to load asset for merge")?
            .ok_or_else(|| anyhow!("merge asset not found for profile"))?;
            currencies.push(asset.currency);
        }
        if currencies[0] != currencies[1] {
            return Err(anyhow!("cannot merge assets with different currencies"));
        }
        let source_snaps = sqlx::query_as::<_, AssetSnapshotRow>(
            "SELECT * FROM asset_snapshots WHERE asset_id = ?1 AND profile_id = ?2 AND deleted_at IS NULL",
        )
        .bind(&source)
        .bind(profile_id)
        .fetch_all(&mut *tx)
        .await
        .context("failed to load source snapshots")?;

        for snap in source_snaps {
            // The unique (asset_id, recorded_on) index also covers tombstones.
            let conflict = sqlx::query_as::<_, AssetSnapshotRow>(
                "SELECT * FROM asset_snapshots WHERE asset_id = ?1 AND recorded_on = ?2",
            )
            .bind(&target)
            .bind(&snap.recorded_on)
            .fetch_optional(&mut *tx)
            .await
            .context("failed to check snapshot conflict")?;

            if let Some(existing) = conflict {
                if existing.deleted_at.is_some() || snap.updated_at >= existing.updated_at {
                    sqlx::query(
                        "UPDATE asset_snapshots SET amount = ?2, note = ?3, deleted_at = NULL, sync_version = sync_version + 1, updated_at = datetime('now') WHERE id = ?1",
                    )
                    .bind(&existing.id)
                    .bind(snap.amount)
                    .bind(&snap.note)
                    .execute(&mut *tx)
                    .await
                    .context("failed to update winning target snapshot")?;
                }
                sqlx::query(
                    "UPDATE asset_snapshots SET deleted_at = datetime('now'), sync_version = sync_version + 1, updated_at = datetime('now') WHERE id = ?1",
                )
                .bind(&snap.id)
                .execute(&mut *tx)
                .await
                .context("failed to delete merged source snapshot")?;
            } else {
                sqlx::query(
                    "UPDATE asset_snapshots SET asset_id = ?2, sync_version = sync_version + 1, updated_at = datetime('now') WHERE id = ?1",
                )
                .bind(&snap.id)
                .bind(&target)
                .execute(&mut *tx)
                .await
                .context("failed to reassign source snapshot")?;
            }
        }
        sqlx::query(
            "UPDATE assets SET deleted_at = datetime('now'), sync_version = sync_version + 1, updated_at = datetime('now') WHERE id = ?1 AND profile_id = ?2",
        )
        .bind(&source)
        .bind(profile_id)
        .execute(&mut *tx)
        .await
        .context("failed to soft-delete source asset")?;
        tx.commit().await.context("failed to commit asset merge")?;
        Ok(())
    }

    pub async fn soft_delete_asset(&self, id: Uuid, profile_id: &str) -> Result<()> {
        let row = sqlx::query_as::<_, AssetRow>(
            r#"
            UPDATE assets
            SET deleted_at = datetime('now'), sync_version = sync_version + 1, updated_at = datetime('now')
            WHERE id = ?1 AND profile_id = ?2 AND deleted_at IS NULL
            RETURNING *
            "#,
        )
        .bind(id.to_string())
        .bind(profile_id)
        .fetch_optional(&self.pool)
        .await
        .context("failed to delete asset")?
        .ok_or_else(|| anyhow!("asset not found"))?;

        let _: Asset = row.try_into()?;
        Ok(())
    }

    pub async fn delete_asset_snapshot(&self, snapshot_id: Uuid, profile_id: &str) -> Result<()> {
        let row = sqlx::query_as::<_, AssetSnapshotRow>(
            r#"
            UPDATE asset_snapshots
            SET deleted_at = datetime('now'), sync_version = sync_version + 1, updated_at = datetime('now')
            WHERE id = ?1 AND profile_id = ?2 AND deleted_at IS NULL
            RETURNING *
            "#,
        )
        .bind(snapshot_id.to_string())
        .bind(profile_id)
        .fetch_optional(&self.pool)
        .await
        .context("failed to delete asset snapshot")?
        .ok_or_else(|| anyhow!("asset snapshot not found"))?;

        let _: AssetSnapshot = row.try_into()?;
        Ok(())
    }

    // ── App settings (generic KV) ───────────────────────────────────────

    pub async fn get_setting(&self, key: &str) -> Result<Option<String>> {
        let row = sqlx::query("SELECT value FROM app_settings WHERE key = ?1")
            .bind(key)
            .fetch_optional(&self.pool)
            .await
            .context("failed to load setting")?;
        Ok(row.map(|r| r.get::<String, _>("value")))
    }

    pub async fn set_setting(&self, key: &str, value: &str) -> Result<()> {
        self.set_setting_with_device(key, value, "").await
    }

    pub async fn set_setting_with_device(
        &self,
        key: &str,
        value: &str,
        device_id: &str,
    ) -> Result<()> {
        sqlx::query(
            r#"
            INSERT INTO app_settings (key, value, updated_at, device_id, sync_version)
            VALUES (?1, ?2, datetime('now'), ?3, 1)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                device_id = excluded.device_id,
                sync_version = sync_version + 1,
                updated_at = excluded.updated_at
            "#,
        )
        .bind(key)
        .bind(value)
        .bind(device_id)
        .execute(&self.pool)
        .await
        .context("failed to save setting")?;
        Ok(())
    }

    pub async fn pending_sync_count(&self, profile_id: &str) -> Result<i64> {
        let row = sqlx::query(
            r#"
            SELECT (
                SELECT COUNT(*) FROM records       WHERE profile_id = ?1 AND sync_version > synced_version
            ) + (
                SELECT COUNT(*) FROM subscriptions WHERE profile_id = ?1 AND sync_version > synced_version
            ) + (
                SELECT COUNT(*) FROM assets        WHERE profile_id = ?1 AND sync_version > synced_version
            ) + (
                SELECT COUNT(*) FROM asset_snapshots WHERE profile_id = ?1 AND sync_version > synced_version
            ) AS count
            "#,
        )
        .bind(profile_id)
        .fetch_one(&self.pool)
        .await
        .context("failed to count pending sync")?;
        Ok(row.get::<i64, _>("count"))
    }

    pub async fn ensure_sync_state(&self, profile_id: &str) -> Result<()> {
        sqlx::query("INSERT OR IGNORE INTO sync_state (profile_id) VALUES (?1)")
            .bind(profile_id)
            .execute(&self.pool)
            .await
            .context("failed to ensure sync state")?;
        Ok(())
    }

    // ── Sync API ────────────────────────────────────────────────────────────

    /// List dirty rows needing push for the given entity types.
    pub async fn list_dirty_records(&self, profile_id: &str, limit: i64) -> Result<Vec<Record>> {
        self.list_dirty_profiled::<RecordRow, Record>(
            "records",
            profile_id,
            limit,
            "failed to list dirty records",
        )
        .await
    }

    pub async fn list_dirty_subscriptions(
        &self,
        profile_id: &str,
        limit: i64,
    ) -> Result<Vec<Subscription>> {
        self.list_dirty_profiled::<SubscriptionRow, Subscription>(
            "subscriptions",
            profile_id,
            limit,
            "failed to list dirty subscriptions",
        )
        .await
    }

    pub async fn list_dirty_assets(&self, profile_id: &str, limit: i64) -> Result<Vec<Asset>> {
        self.list_dirty_profiled::<AssetRow, Asset>(
            "assets",
            profile_id,
            limit,
            "failed to list dirty assets",
        )
        .await
    }

    pub async fn list_dirty_asset_snapshots(
        &self,
        profile_id: &str,
        limit: i64,
    ) -> Result<Vec<AssetSnapshot>> {
        self.list_dirty_profiled::<AssetSnapshotRow, AssetSnapshot>(
            "asset_snapshots",
            profile_id,
            limit,
            "failed to list dirty asset snapshots",
        )
        .await
    }

    // app_settings has no profile_id column — settings are global to the installation.
    pub async fn list_dirty_settings(&self, limit: i64) -> Result<Vec<AppSetting>> {
        let rows = sqlx::query_as::<_, AppSettingRow>(
            "SELECT * FROM app_settings WHERE sync_version > synced_version ORDER BY updated_at ASC LIMIT ?1",
        )
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .context("failed to list dirty settings")?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    async fn list_dirty_profiled<R, T>(
        &self,
        table: &'static str,
        profile_id: &str,
        limit: i64,
        error_context: &'static str,
    ) -> Result<Vec<T>>
    where
        for<'r> R: FromRow<'r, SqliteRow> + Send + Unpin,
        T: TryFrom<R, Error = anyhow::Error>,
    {
        let sql = format!(
            "SELECT * FROM {table} WHERE profile_id = ?1 AND sync_version > synced_version ORDER BY updated_at ASC LIMIT ?2"
        );
        let rows = sqlx::query_as::<_, R>(&sql)
            .bind(profile_id)
            .bind(limit)
            .fetch_all(&self.pool)
            .await
            .context(error_context)?;
        rows.into_iter().map(TryInto::try_into).collect()
    }

    /// Advance synced_version only when the row's sync_version still matches what was pushed.
    pub async fn mark_record_synced(&self, id: Uuid, synced_version: i64) -> Result<()> {
        self.mark_records_synced(&[(id, synced_version)]).await?;
        Ok(())
    }

    pub async fn mark_subscription_synced(&self, id: Uuid, synced_version: i64) -> Result<()> {
        self.mark_subscriptions_synced(&[(id, synced_version)])
            .await?;
        Ok(())
    }

    pub async fn mark_setting_synced(&self, key: &str, synced_version: i64) -> Result<()> {
        self.mark_settings_synced(&[(key.to_string(), synced_version)])
            .await?;
        Ok(())
    }

    pub async fn mark_records_synced(&self, entries: &[(Uuid, i64)]) -> Result<u64> {
        self.mark_uuid_entities_synced("records", entries, "failed to mark records synced")
            .await
    }

    pub async fn mark_subscriptions_synced(&self, entries: &[(Uuid, i64)]) -> Result<u64> {
        self.mark_uuid_entities_synced(
            "subscriptions",
            entries,
            "failed to mark subscriptions synced",
        )
        .await
    }

    pub async fn mark_assets_synced(&self, entries: &[(Uuid, i64)]) -> Result<u64> {
        self.mark_uuid_entities_synced("assets", entries, "failed to mark assets synced")
            .await
    }

    pub async fn mark_asset_snapshots_synced(&self, entries: &[(Uuid, i64)]) -> Result<u64> {
        self.mark_uuid_entities_synced(
            "asset_snapshots",
            entries,
            "failed to mark asset snapshots synced",
        )
        .await
    }

    pub async fn mark_settings_synced(&self, entries: &[(String, i64)]) -> Result<u64> {
        if entries.is_empty() {
            return Ok(0);
        }
        let mut query = QueryBuilder::<Sqlite>::new(
            "UPDATE app_settings SET synced_version = sync_version WHERE (key, sync_version) IN (",
        );
        for (index, (key, version)) in entries.iter().enumerate() {
            if index > 0 {
                query.push(", ");
            }
            query
                .push("(")
                .push_bind(key)
                .push(", ")
                .push_bind(version)
                .push(")");
        }
        query.push(")");

        let result = query
            .build()
            .execute(&self.pool)
            .await
            .context("failed to mark settings synced")?;
        Ok(result.rows_affected())
    }

    async fn mark_uuid_entities_synced(
        &self,
        table: &'static str,
        entries: &[(Uuid, i64)],
        error_context: &'static str,
    ) -> Result<u64> {
        if entries.is_empty() {
            return Ok(0);
        }
        let mut query = QueryBuilder::<Sqlite>::new(format!(
            "UPDATE {table} SET synced_version = sync_version WHERE (id, sync_version) IN ("
        ));
        for (index, (id, version)) in entries.iter().enumerate() {
            if index > 0 {
                query.push(", ");
            }
            query
                .push("(")
                .push_bind(id.to_string())
                .push(", ")
                .push_bind(version)
                .push(")");
        }
        query.push(")");

        let result = query
            .build()
            .execute(&self.pool)
            .await
            .context(error_context)?;
        Ok(result.rows_affected())
    }

    /// LWW upsert for a remote record. Only applies if remote wins (higher version, or same version with later updated_at).
    pub async fn apply_remote_record(&self, remote: Record) -> Result<bool> {
        let result = sqlx::query(
            r#"
            INSERT INTO records (
                id, profile_id, direction, amount, currency, category, merchant,
                transaction_at, note, device_id, sync_version, synced_version, deleted_at, created_at, updated_at
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?11, ?12, ?13, ?14)
            ON CONFLICT(id) DO UPDATE SET
                direction = excluded.direction,
                amount = excluded.amount,
                currency = excluded.currency,
                category = excluded.category,
                merchant = excluded.merchant,
                transaction_at = excluded.transaction_at,
                note = excluded.note,
                deleted_at = excluded.deleted_at,
                sync_version = excluded.sync_version,
                synced_version = excluded.sync_version,
                updated_at = excluded.updated_at
            WHERE excluded.sync_version > sync_version
               OR (excluded.sync_version = sync_version AND excluded.updated_at > updated_at)
            "#,
        )
        .bind(remote.id.to_string())
        .bind(&remote.profile_id)
        .bind(remote.direction.as_str())
        .bind(remote.amount)
        .bind(&remote.currency)
        .bind(&remote.category)
        .bind(&remote.merchant)
        .bind(remote.transaction_at)
        .bind(&remote.note)
        .bind(&remote.device_id)
        .bind(remote.sync_version)
        .bind(remote.deleted_at)
        .bind(remote.created_at)
        .bind(remote.updated_at)
        .execute(&self.pool)
        .await
        .context("failed to apply remote record")?;
        Ok(result.rows_affected() > 0)
    }

    pub async fn apply_remote_subscription(&self, remote: Subscription) -> Result<bool> {
        let result = sqlx::query(
            r#"
            INSERT INTO subscriptions (
                id, profile_id, direction, amount, currency, category, merchant, note,
                cycle, anchor_day, anchor_month, next_due_at, last_charged_at, is_active,
                deleted_at, sync_version, synced_version, device_id, created_at, updated_at
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?16, ?17, ?18, ?19)
            ON CONFLICT(id) DO UPDATE SET
                direction = excluded.direction,
                amount = excluded.amount,
                currency = excluded.currency,
                category = excluded.category,
                merchant = excluded.merchant,
                note = excluded.note,
                cycle = excluded.cycle,
                anchor_day = excluded.anchor_day,
                anchor_month = excluded.anchor_month,
                next_due_at = excluded.next_due_at,
                last_charged_at = excluded.last_charged_at,
                is_active = excluded.is_active,
                deleted_at = excluded.deleted_at,
                sync_version = excluded.sync_version,
                synced_version = excluded.sync_version,
                updated_at = excluded.updated_at
            WHERE excluded.sync_version > sync_version
               OR (excluded.sync_version = sync_version AND excluded.updated_at > updated_at)
            "#,
        )
        .bind(remote.id.to_string())
        .bind(&remote.profile_id)
        .bind(remote.direction.as_str())
        .bind(remote.amount)
        .bind(&remote.currency)
        .bind(&remote.category)
        .bind(&remote.merchant)
        .bind(&remote.note)
        .bind(remote.cycle.as_str())
        .bind(remote.anchor_day)
        .bind(remote.anchor_month)
        .bind(remote.next_due_at.to_string())
        .bind(remote.last_charged_at.map(|d| d.to_string()))
        .bind(remote.is_active as i64)
        .bind(remote.deleted_at)
        .bind(remote.sync_version)
        .bind(&remote.device_id)
        .bind(remote.created_at)
        .bind(remote.updated_at)
        .execute(&self.pool)
        .await
        .context("failed to apply remote subscription")?;
        Ok(result.rows_affected() > 0)
    }

    pub async fn apply_remote_asset(&self, remote: Asset) -> Result<bool> {
        // If a live asset with the same (profile_id, name) but a different id exists and the
        // remote wins on version, soft-delete the local row first so the partial unique index
        // on (profile_id, name) WHERE deleted_at IS NULL doesn't block the upsert.
        sqlx::query(
            r#"
            UPDATE assets
            SET deleted_at = datetime('now'),
                sync_version = sync_version + 1
            WHERE profile_id = ?1 AND name = ?2 AND id != ?3
              AND deleted_at IS NULL
              AND (?4 > sync_version
                   OR (?4 = sync_version AND ?5 > updated_at))
            "#,
        )
        .bind(&remote.profile_id)
        .bind(&remote.name)
        .bind(remote.id.to_string())
        .bind(remote.sync_version)
        .bind(remote.updated_at.to_string())
        .execute(&self.pool)
        .await
        .context("failed to tombstone conflicting asset")?;

        // If the tombstone above didn't fire (local won LWW), the partial unique index on
        // (profile_id, name) WHERE deleted_at IS NULL would block the insert. Skip it.
        let conflict: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM assets WHERE profile_id = ?1 AND name = ?2 AND id != ?3 AND deleted_at IS NULL)",
        )
        .bind(&remote.profile_id)
        .bind(&remote.name)
        .bind(remote.id.to_string())
        .fetch_one(&self.pool)
        .await
        .context("failed to check conflicting asset")?;
        if conflict {
            return Ok(false);
        }

        let result = sqlx::query(
            r#"
            INSERT INTO assets (id, profile_id, name, category, currency, note, deleted_at, sync_version, synced_version, device_id, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8, ?9, ?10, ?11)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                category = excluded.category,
                currency = excluded.currency,
                note = excluded.note,
                deleted_at = excluded.deleted_at,
                sync_version = excluded.sync_version,
                synced_version = excluded.sync_version,
                updated_at = excluded.updated_at
            WHERE excluded.sync_version > sync_version
               OR (excluded.sync_version = sync_version AND excluded.updated_at > updated_at)
            "#,
        )
        .bind(remote.id.to_string())
        .bind(&remote.profile_id)
        .bind(&remote.name)
        .bind(&remote.category)
        .bind(&remote.currency)
        .bind(&remote.note)
        .bind(remote.deleted_at)
        .bind(remote.sync_version)
        .bind(&remote.device_id)
        .bind(remote.created_at)
        .bind(remote.updated_at)
        .execute(&self.pool)
        .await
        .context("failed to apply remote asset")?;
        Ok(result.rows_affected() > 0)
    }

    pub async fn apply_remote_asset_snapshot(&self, remote: AssetSnapshot) -> Result<bool> {
        // Tombstone a conflicting live snapshot with the same (asset_id, recorded_on) if remote wins LWW.
        // Migration 0007 made the unique index partial (WHERE deleted_at IS NULL) so this unblocks the insert.
        sqlx::query(
            r#"
            UPDATE asset_snapshots
            SET deleted_at = datetime('now'),
                sync_version = sync_version + 1
            WHERE asset_id = ?1 AND recorded_on = ?2 AND id != ?3
              AND deleted_at IS NULL
              AND (?4 > sync_version
                   OR (?4 = sync_version AND ?5 > updated_at))
            "#,
        )
        .bind(remote.asset_id.to_string())
        .bind(&remote.recorded_on)
        .bind(remote.id.to_string())
        .bind(remote.sync_version)
        .bind(remote.updated_at.to_string())
        .execute(&self.pool)
        .await
        .context("failed to tombstone conflicting snapshot")?;

        // If local won, its row is still live — skip the remote insert.
        let conflict: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM asset_snapshots WHERE asset_id = ?1 AND recorded_on = ?2 AND id != ?3 AND deleted_at IS NULL)",
        )
        .bind(remote.asset_id.to_string())
        .bind(&remote.recorded_on)
        .bind(remote.id.to_string())
        .fetch_one(&self.pool)
        .await
        .context("failed to check conflicting snapshot")?;
        if conflict {
            return Ok(false);
        }

        let result = sqlx::query(
            r#"
            INSERT INTO asset_snapshots (id, asset_id, profile_id, amount, recorded_on, note, deleted_at, sync_version, synced_version, device_id, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8, ?9, ?10, ?11)
            ON CONFLICT(id) DO UPDATE SET
                amount = excluded.amount,
                note = excluded.note,
                deleted_at = excluded.deleted_at,
                sync_version = excluded.sync_version,
                synced_version = excluded.sync_version,
                updated_at = excluded.updated_at
            WHERE excluded.sync_version > sync_version
               OR (excluded.sync_version = sync_version AND excluded.updated_at > updated_at)
            "#,
        )
        .bind(remote.id.to_string())
        .bind(remote.asset_id.to_string())
        .bind(&remote.profile_id)
        .bind(remote.amount)
        .bind(&remote.recorded_on)
        .bind(&remote.note)
        .bind(remote.deleted_at)
        .bind(remote.sync_version)
        .bind(&remote.device_id)
        .bind(remote.created_at)
        .bind(remote.updated_at)
        .execute(&self.pool)
        .await
        .context("failed to apply remote asset snapshot")?;
        Ok(result.rows_affected() > 0)
    }

    pub async fn apply_remote_setting(&self, remote: AppSetting) -> Result<bool> {
        let result = sqlx::query(
            r#"
            INSERT INTO app_settings (key, value, sync_version, synced_version, deleted_at, device_id, updated_at)
            VALUES (?1, ?2, ?3, ?3, ?4, ?5, ?6)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                deleted_at = excluded.deleted_at,
                sync_version = excluded.sync_version,
                synced_version = excluded.sync_version,
                updated_at = excluded.updated_at
            WHERE excluded.sync_version > sync_version
               OR (excluded.sync_version = sync_version AND excluded.updated_at > updated_at)
            "#,
        )
        .bind(&remote.key)
        .bind(&remote.value)
        .bind(remote.sync_version)
        .bind(remote.deleted_at)
        .bind(&remote.device_id)
        .bind(remote.updated_at)
        .execute(&self.pool)
        .await
        .context("failed to apply remote setting")?;
        Ok(result.rows_affected() > 0)
    }

    pub async fn get_sync_cursor(&self, profile_id: &str, zone: &str) -> Result<Option<String>> {
        let row = sqlx::query("SELECT token FROM sync_cursor WHERE profile_id = ?1 AND zone = ?2")
            .bind(profile_id)
            .bind(zone)
            .fetch_optional(&self.pool)
            .await
            .context("failed to load sync cursor")?;
        Ok(row.and_then(|r| r.get::<Option<String>, _>("token")))
    }

    pub async fn set_sync_cursor(
        &self,
        profile_id: &str,
        zone: &str,
        token: Option<&str>,
    ) -> Result<()> {
        sqlx::query(
            r#"
            INSERT INTO sync_cursor (profile_id, zone, token, updated_at)
            VALUES (?1, ?2, ?3, datetime('now'))
            ON CONFLICT(profile_id, zone) DO UPDATE SET token = excluded.token, updated_at = excluded.updated_at
            "#,
        )
        .bind(profile_id)
        .bind(zone)
        .bind(token)
        .execute(&self.pool)
        .await
        .context("failed to save sync cursor")?;
        Ok(())
    }

    pub async fn upsert_fx_rate(
        &self,
        base_currency: &str,
        quote_currency: &str,
        rate: f64,
        rate_date: NaiveDate,
        fetched_at: DateTime<Utc>,
    ) -> Result<()> {
        sqlx::query(
            r#"
            INSERT INTO fx_rates (base_currency, quote_currency, rate, rate_date, fetched_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(base_currency, quote_currency, rate_date)
            DO UPDATE SET
                rate = excluded.rate,
                fetched_at = excluded.fetched_at
            "#,
        )
        .bind(base_currency)
        .bind(quote_currency)
        .bind(rate)
        .bind(rate_date.to_string())
        .bind(fetched_at)
        .execute(&self.pool)
        .await
        .context("failed to upsert fx rate")?;
        Ok(())
    }

    pub async fn latest_fx_rate(
        &self,
        base_currency: &str,
        quote_currency: &str,
    ) -> Result<Option<FxRateCache>> {
        let row = sqlx::query_as::<_, FxRateRow>(
            r#"
            SELECT base_currency, quote_currency, rate, rate_date, fetched_at
            FROM fx_rates
            WHERE base_currency = ?1 AND quote_currency = ?2
            ORDER BY fetched_at DESC, rate_date DESC
            LIMIT 1
            "#,
        )
        .bind(base_currency)
        .bind(quote_currency)
        .fetch_optional(&self.pool)
        .await
        .context("failed to load cached fx rate")?;

        row.map(TryInto::try_into).transpose()
    }
}

fn parsed_draft_kind(payload: &ParsedRecordPayload) -> Result<ParsedDraftKind> {
    match (
        payload.asset_info.is_some(),
        payload.subscription_cycle.is_some(),
    ) {
        (true, true) => Err(anyhow!(
            "parsed payload cannot be both an asset and a subscription"
        )),
        (true, false) => Ok(ParsedDraftKind::Asset),
        (false, true) => Ok(ParsedDraftKind::Subscription),
        (false, false) => Ok(ParsedDraftKind::Record),
    }
}

async fn insert_record_in_transaction(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    profile_id: &str,
    device_id: &str,
    create: RecordCreate,
) -> Result<Record> {
    let record_id = Uuid::new_v4();
    let row = sqlx::query_as::<_, RecordRow>(
        r#"
        INSERT INTO records (
            id, profile_id, direction, amount, currency, category,
            merchant, transaction_at, note, device_id
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        RETURNING *
        "#,
    )
    .bind(record_id.to_string())
    .bind(profile_id)
    .bind(create.direction.as_str())
    .bind(create.amount)
    .bind(create.currency)
    .bind(create.category)
    .bind(create.merchant)
    .bind(create.transaction_at)
    .bind(create.note)
    .bind(device_id)
    .fetch_one(&mut **tx)
    .await
    .context("failed to insert record while confirming parsed draft")?;
    row.try_into()
}

async fn confirm_asset_in_transaction(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    profile_id: &str,
    device_id: &str,
    create: AssetConfirmationCreate,
) -> Result<ParsedDraftConfirmation> {
    let asset_id = Uuid::new_v4();
    let asset_row = sqlx::query_as::<_, AssetRow>(
        r#"
        INSERT INTO assets (id, profile_id, name, category, currency, device_id)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        ON CONFLICT (profile_id, name) WHERE deleted_at IS NULL
        DO UPDATE SET
            category = excluded.category,
            currency = excluded.currency,
            sync_version = assets.sync_version + 1,
            device_id = excluded.device_id,
            updated_at = datetime('now')
        RETURNING *
        "#,
    )
    .bind(asset_id.to_string())
    .bind(profile_id)
    .bind(create.name)
    .bind(create.category)
    .bind(create.currency)
    .bind(device_id)
    .fetch_one(&mut **tx)
    .await
    .context("failed to upsert asset while confirming parsed draft")?;
    let asset: Asset = asset_row.try_into()?;

    let snapshot_id = Uuid::new_v4();
    let snapshot_row = sqlx::query_as::<_, AssetSnapshotRow>(
        r#"
        INSERT INTO asset_snapshots (
            id, asset_id, profile_id, amount, recorded_on, note, device_id
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        ON CONFLICT (asset_id, recorded_on) WHERE deleted_at IS NULL
        DO UPDATE SET
            amount = excluded.amount,
            note = excluded.note,
            sync_version = asset_snapshots.sync_version + 1,
            device_id = excluded.device_id,
            updated_at = datetime('now')
        RETURNING *
        "#,
    )
    .bind(snapshot_id.to_string())
    .bind(asset.id.to_string())
    .bind(profile_id)
    .bind(create.amount)
    .bind(create.recorded_on.to_string())
    .bind(create.note)
    .bind(device_id)
    .fetch_one(&mut **tx)
    .await
    .context("failed to upsert asset snapshot while confirming parsed draft")?;
    let snapshot: AssetSnapshot = snapshot_row.try_into()?;

    Ok(ParsedDraftConfirmation {
        asset_id: Some(asset.id),
        asset_snapshot_id: Some(snapshot.id),
        ..Default::default()
    })
}

#[derive(Debug, FromRow)]
struct RecordRow {
    id: String,
    profile_id: String,
    direction: String,
    amount: f64,
    currency: String,
    category: String,
    merchant: Option<String>,
    transaction_at: DateTime<Utc>,
    note: Option<String>,
    device_id: String,
    sync_version: i64,
    synced_version: i64,
    deleted_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl TryFrom<RecordRow> for Record {
    type Error = anyhow::Error;

    fn try_from(row: RecordRow) -> Result<Self> {
        Ok(Self {
            id: Uuid::parse_str(&row.id).context("invalid record id")?,
            profile_id: row.profile_id,
            direction: RecordDirection::try_from(row.direction.as_str())
                .map_err(anyhow::Error::msg)?,
            amount: row.amount,
            currency: row.currency,
            category: row.category,
            merchant: row.merchant,
            transaction_at: row.transaction_at,
            note: row.note,
            device_id: row.device_id,
            sync_version: row.sync_version,
            synced_version: row.synced_version,
            deleted_at: row.deleted_at,
            created_at: row.created_at,
            updated_at: row.updated_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct RecordDraftRow {
    id: String,
    batch_id: String,
    profile_id: String,
    kind: String,
    parser_source: String,
    original_content: String,
    payload_json: String,
    fallback_reason: Option<String>,
    status: String,
    confirmation_json: Option<String>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl TryFrom<RecordDraftRow> for RecordDraft {
    type Error = anyhow::Error;

    fn try_from(row: RecordDraftRow) -> Result<Self> {
        let payload: ParsedRecordPayload =
            serde_json::from_str(&row.payload_json).context("invalid parsed draft payload JSON")?;
        let confirmation: Option<ParsedDraftConfirmation> = row
            .confirmation_json
            .as_deref()
            .map(serde_json::from_str)
            .transpose()
            .context("invalid parsed draft confirmation JSON")?;
        Ok(Self {
            id: Uuid::parse_str(&row.id).context("invalid draft id")?,
            batch_id: Uuid::parse_str(&row.batch_id).context("invalid draft batch id")?,
            profile_id: row.profile_id,
            content: row.original_content,
            auto_confirm: false,
            kind: ParsedDraftKind::try_from(row.kind.as_str()).map_err(anyhow::Error::msg)?,
            parser_source: ParserSource::try_from(row.parser_source.as_str())
                .map_err(anyhow::Error::msg)?,
            fallback_reason: row.fallback_reason,
            status: RecordDraftStatus::try_from(row.status.as_str()).map_err(anyhow::Error::msg)?,
            confirmed_record_id: confirmation.as_ref().and_then(|value| value.record_id),
            direction: payload.direction,
            amount: payload.amount,
            currency: payload.currency,
            category: payload.category,
            merchant: payload.merchant,
            transaction_at: payload.transaction_at,
            note: payload.note,
            subscription_cycle: payload.subscription_cycle,
            asset_info: payload.asset_info,
            confirmation,
            created_at: row.created_at,
            updated_at: row.updated_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct ConversationMessageRow {
    id: String,
    profile_id: String,
    role: String,
    content: String,
    draft_id: Option<String>,
    record_id: Option<String>,
    created_at: DateTime<Utc>,
}

impl TryFrom<ConversationMessageRow> for ConversationMessage {
    type Error = anyhow::Error;

    fn try_from(row: ConversationMessageRow) -> Result<Self> {
        Ok(Self {
            id: Uuid::parse_str(&row.id).context("invalid message id")?,
            profile_id: row.profile_id,
            role: ConversationRole::try_from(row.role.as_str()).map_err(anyhow::Error::msg)?,
            content: row.content,
            draft_id: row
                .draft_id
                .map(|value| Uuid::parse_str(&value).context("invalid draft reference"))
                .transpose()?,
            record_id: row
                .record_id
                .map(|value| Uuid::parse_str(&value).context("invalid record reference"))
                .transpose()?,
            created_at: row.created_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct FxRateRow {
    base_currency: String,
    quote_currency: String,
    rate: f64,
    rate_date: String,
    fetched_at: DateTime<Utc>,
}

impl TryFrom<FxRateRow> for FxRateCache {
    type Error = anyhow::Error;

    fn try_from(row: FxRateRow) -> Result<Self> {
        Ok(Self {
            base_currency: row.base_currency,
            quote_currency: row.quote_currency,
            rate: row.rate,
            rate_date: NaiveDate::parse_from_str(&row.rate_date, "%Y-%m-%d")
                .context("invalid fx rate_date")?,
            fetched_at: row.fetched_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct SubscriptionRow {
    id: String,
    profile_id: String,
    direction: String,
    amount: f64,
    currency: String,
    category: String,
    merchant: Option<String>,
    note: Option<String>,
    cycle: String,
    anchor_day: i32,
    anchor_month: Option<i32>,
    next_due_at: String,
    last_charged_at: Option<String>,
    is_active: i64,
    deleted_at: Option<DateTime<Utc>>,
    sync_version: i64,
    synced_version: i64,
    device_id: String,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl TryFrom<SubscriptionRow> for Subscription {
    type Error = anyhow::Error;

    fn try_from(row: SubscriptionRow) -> Result<Self> {
        Ok(Self {
            id: Uuid::parse_str(&row.id).context("invalid subscription id")?,
            profile_id: row.profile_id,
            direction: RecordDirection::try_from(row.direction.as_str())
                .map_err(anyhow::Error::msg)?,
            amount: row.amount,
            currency: row.currency,
            category: row.category,
            merchant: row.merchant,
            note: row.note,
            cycle: SubscriptionCycle::try_from(row.cycle.as_str()).map_err(anyhow::Error::msg)?,
            anchor_day: row.anchor_day,
            anchor_month: row.anchor_month,
            next_due_at: NaiveDate::parse_from_str(&row.next_due_at, "%Y-%m-%d")
                .context("invalid subscription next_due_at")?,
            last_charged_at: row
                .last_charged_at
                .map(|v| {
                    NaiveDate::parse_from_str(&v, "%Y-%m-%d").context("invalid last_charged_at")
                })
                .transpose()?,
            is_active: row.is_active != 0,
            deleted_at: row.deleted_at,
            sync_version: row.sync_version,
            synced_version: row.synced_version,
            device_id: row.device_id,
            created_at: row.created_at,
            updated_at: row.updated_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct AssetRow {
    id: String,
    profile_id: String,
    name: String,
    category: String,
    currency: String,
    note: Option<String>,
    deleted_at: Option<DateTime<Utc>>,
    sync_version: i64,
    synced_version: i64,
    device_id: String,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl TryFrom<AssetRow> for Asset {
    type Error = anyhow::Error;

    fn try_from(row: AssetRow) -> Result<Self> {
        Ok(Self {
            id: Uuid::parse_str(&row.id).context("invalid asset id")?,
            profile_id: row.profile_id,
            name: row.name,
            category: row.category,
            currency: row.currency,
            note: row.note,
            deleted_at: row.deleted_at,
            sync_version: row.sync_version,
            synced_version: row.synced_version,
            device_id: row.device_id,
            created_at: row.created_at,
            updated_at: row.updated_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct AssetSnapshotRow {
    id: String,
    asset_id: String,
    profile_id: String,
    amount: f64,
    recorded_on: String,
    note: Option<String>,
    deleted_at: Option<DateTime<Utc>>,
    sync_version: i64,
    synced_version: i64,
    device_id: String,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl TryFrom<AssetSnapshotRow> for AssetSnapshot {
    type Error = anyhow::Error;

    fn try_from(row: AssetSnapshotRow) -> Result<Self> {
        Ok(Self {
            id: Uuid::parse_str(&row.id).context("invalid asset snapshot id")?,
            asset_id: Uuid::parse_str(&row.asset_id).context("invalid asset snapshot asset_id")?,
            profile_id: row.profile_id,
            amount: row.amount,
            recorded_on: row.recorded_on,
            note: row.note,
            deleted_at: row.deleted_at,
            sync_version: row.sync_version,
            synced_version: row.synced_version,
            device_id: row.device_id,
            created_at: row.created_at,
            updated_at: row.updated_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct AppSettingRow {
    key: String,
    value: String,
    sync_version: i64,
    synced_version: i64,
    deleted_at: Option<DateTime<Utc>>,
    device_id: String,
    updated_at: DateTime<Utc>,
}

impl From<AppSettingRow> for AppSetting {
    fn from(row: AppSettingRow) -> Self {
        Self {
            key: row.key,
            value: row.value,
            sync_version: row.sync_version,
            synced_version: row.synced_version,
            deleted_at: row.deleted_at,
            device_id: row.device_id,
            updated_at: row.updated_at,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record_payload(amount: f64) -> ParsedRecordPayload {
        ParsedRecordPayload {
            direction: Some(RecordDirection::Expense),
            amount: Some(amount),
            currency: Some("CNY".to_string()),
            category: Some("餐饮".to_string()),
            merchant: Some("测试商户".to_string()),
            transaction_at: Some(Utc::now()),
            note: None,
            subscription_cycle: None,
            asset_info: None,
        }
    }

    fn record_create(amount: f64) -> RecordCreate {
        RecordCreate {
            direction: RecordDirection::Expense,
            amount,
            currency: "CNY".to_string(),
            category: "餐饮".to_string(),
            merchant: Some("测试商户".to_string()),
            transaction_at: Utc::now(),
            note: None,
        }
    }

    fn asset_payload() -> ParsedRecordPayload {
        ParsedRecordPayload {
            direction: None,
            amount: None,
            currency: None,
            category: None,
            merchant: None,
            transaction_at: None,
            note: None,
            subscription_cycle: None,
            asset_info: Some(ParsedAssetInfo {
                name: "测试银行".to_string(),
                category: Some("存款".to_string()),
                amount: 10_000.0,
                currency: Some("CNY".to_string()),
                recorded_on: Some("2026-07-14".to_string()),
                note: None,
            }),
        }
    }

    fn asset_action() -> ParsedDraftConfirmationAction {
        ParsedDraftConfirmationAction::Asset(AssetConfirmationCreate {
            name: "测试银行".to_string(),
            category: "存款".to_string(),
            amount: 10_000.0,
            currency: "CNY".to_string(),
            recorded_on: NaiveDate::from_ymd_opt(2026, 7, 14).unwrap(),
            note: None,
        })
    }

    fn subscription_payload() -> ParsedRecordPayload {
        let mut payload = record_payload(28.0);
        payload.category = Some("订阅".to_string());
        payload.subscription_cycle = Some(SubscriptionCycle::Monthly);
        payload
    }

    fn subscription_action() -> ParsedDraftConfirmationAction {
        ParsedDraftConfirmationAction::Subscription {
            record: RecordCreate {
                category: "订阅".to_string(),
                ..record_create(28.0)
            },
            subscription: SubscriptionCreate {
                direction: RecordDirection::Expense,
                amount: 28.0,
                currency: "CNY".to_string(),
                category: "订阅".to_string(),
                merchant: Some("测试商户".to_string()),
                note: None,
                cycle: SubscriptionCycle::Monthly,
                anchor_day: 14,
                anchor_month: None,
                next_due_at: NaiveDate::from_ymd_opt(2026, 8, 14).unwrap(),
            },
        }
    }

    async fn asset_merge_fixture() -> (BillRepository, Asset, Asset) {
        let path = std::env::temp_dir().join(format!("billlens-merge-{}.sqlite", Uuid::new_v4()));
        let repo = BillRepository::connect(path).await.unwrap();
        let source = repo
            .find_or_create_asset("p1", "device", "source", "存款", "CNY")
            .await
            .unwrap();
        let target = repo
            .find_or_create_asset("p1", "device", "target", "存款", "CNY")
            .await
            .unwrap();
        repo.upsert_asset_snapshot(
            source.id,
            "p1",
            "device",
            "2026-10-22",
            20.0,
            Some("source"),
        )
        .await
        .unwrap();
        repo.upsert_asset_snapshot(
            target.id,
            "p1",
            "device",
            "2026-10-22",
            10.0,
            Some("target"),
        )
        .await
        .unwrap();
        sqlx::query("UPDATE asset_snapshots SET updated_at = '2026-10-22 00:00:00'")
            .execute(repo.pool())
            .await
            .unwrap();
        (repo, source, target)
    }

    #[tokio::test]
    async fn asset_merge_keeps_target_identity_for_same_day() {
        let (repo, source, target) = asset_merge_fixture().await;
        repo.merge_asset_into(source.id, target.id, "p1")
            .await
            .unwrap();
        let assets = repo.list_assets_with_snapshots("p1").await.unwrap();
        assert_eq!(assets.len(), 1);
        assert_eq!(assets[0].id, target.id);
        assert_eq!(assets[0].snapshots.len(), 1);
        assert_eq!(assets[0].snapshots[0].amount, 20.0);
        assert_eq!(assets[0].snapshots[0].note.as_deref(), Some("source"));
    }

    #[tokio::test]
    async fn asset_merge_reuses_soft_deleted_target_snapshot() {
        let (repo, source, target) = asset_merge_fixture().await;
        let target_snapshot = repo
            .list_assets_with_snapshots("p1")
            .await
            .unwrap()
            .into_iter()
            .find(|a| a.id == target.id)
            .unwrap()
            .snapshots[0]
            .id;
        repo.delete_asset_snapshot(target_snapshot, "p1")
            .await
            .unwrap();
        repo.merge_asset_into(source.id, target.id, "p1")
            .await
            .unwrap();
        let assets = repo.list_assets_with_snapshots("p1").await.unwrap();
        assert_eq!(assets[0].snapshots[0].id, target_snapshot);
        assert_eq!(assets[0].snapshots[0].amount, 20.0);
    }

    #[tokio::test]
    async fn asset_merge_failure_rolls_back_snapshots_and_source() {
        let (repo, source, target) = asset_merge_fixture().await;
        sqlx::query("CREATE TRIGGER fail_merge BEFORE UPDATE OF deleted_at ON assets BEGIN SELECT RAISE(ABORT, 'injected merge failure'); END;")
            .execute(repo.pool()).await.unwrap();
        assert!(
            repo.merge_asset_into(source.id, target.id, "p1")
                .await
                .is_err()
        );
        let assets = repo.list_assets_with_snapshots("p1").await.unwrap();
        assert_eq!(assets.len(), 2);
        assert_eq!(
            assets.iter().find(|a| a.id == source.id).unwrap().snapshots[0].amount,
            20.0
        );
        assert_eq!(
            assets.iter().find(|a| a.id == target.id).unwrap().snapshots[0].amount,
            10.0
        );
    }

    #[tokio::test]
    async fn asset_merge_rejects_wrong_profile_self_and_mixed_currencies() {
        let (repo, source, target) = asset_merge_fixture().await;
        assert!(
            repo.merge_asset_into(source.id, target.id, "other")
                .await
                .is_err()
        );
        assert!(
            repo.merge_asset_into(source.id, source.id, "p1")
                .await
                .is_err()
        );
        let usd = repo
            .find_or_create_asset("p1", "device", "usd", "存款", "USD")
            .await
            .unwrap();
        assert!(
            repo.merge_asset_into(source.id, usd.id, "p1")
                .await
                .is_err()
        );
        assert_eq!(repo.list_assets("p1").await.unwrap().len(), 3);
    }

    #[tokio::test]
    async fn rule_parser_source_is_persisted_after_migration() {
        let repo = make_repo().await;
        let payload = ParsedRecordPayload {
            direction: Some(RecordDirection::Expense),
            amount: Some(100.0),
            currency: Some("CNY".to_string()),
            category: Some("交通".to_string()),
            merchant: None,
            transaction_at: Some(Utc::now()),
            note: None,
            subscription_cycle: None,
            asset_info: None,
        };
        let draft = repo
            .create_parsed_drafts_batch(
                "rule-profile",
                "今天早上打车花了100元",
                &[payload],
                ParserSource::Rule,
                None,
            )
            .await
            .unwrap()
            .remove(0);
        assert_eq!(draft.parser_source, ParserSource::Rule);
    }

    async fn assert_injected_confirmation_failure_rolls_back(
        profile: &str,
        trigger: &str,
        payload: ParsedRecordPayload,
        action: ParsedDraftConfirmationAction,
    ) {
        let repo = make_repo().await;
        let draft = repo
            .create_parsed_drafts_batch(profile, "故障注入", &[payload], ParserSource::Local, None)
            .await
            .unwrap()
            .remove(0);
        sqlx::raw_sql(trigger).execute(repo.pool()).await.unwrap();

        let error = repo
            .confirm_parsed_drafts(profile, "device-test", vec![(draft.id, action)], "不应写入")
            .await
            .unwrap_err();
        assert!(format!("{error:#}").contains("injected failure"));

        for table in [
            "records",
            "assets",
            "asset_snapshots",
            "subscriptions",
            "conversation_messages",
        ] {
            let count: i64 = sqlx::query_scalar(&format!("SELECT COUNT(*) FROM {table}"))
                .fetch_one(repo.pool())
                .await
                .unwrap();
            assert_eq!(count, 0, "{table} was not rolled back");
        }
        let remaining = repo.list_active_record_drafts(profile).await.unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].status, RecordDraftStatus::Parsed);
    }

    #[tokio::test]
    async fn local_drafts_do_not_write_business_tables_before_confirmation() {
        let repo = make_repo().await;
        let profile = "local-draft-profile";
        let mut subscription = record_payload(28.0);
        subscription.category = Some("订阅".to_string());
        subscription.subscription_cycle = Some(SubscriptionCycle::Monthly);
        let asset = ParsedRecordPayload {
            direction: None,
            amount: None,
            currency: None,
            category: None,
            merchant: None,
            transaction_at: None,
            note: None,
            subscription_cycle: None,
            asset_info: Some(ParsedAssetInfo {
                name: "测试银行".to_string(),
                category: Some("存款".to_string()),
                amount: 10_000.0,
                currency: Some("CNY".to_string()),
                recorded_on: Some("2026-07-14".to_string()),
                note: None,
            }),
        };

        let drafts = repo
            .create_parsed_drafts_batch(
                profile,
                "原始输入",
                &[record_payload(18.0), asset, subscription],
                ParserSource::Local,
                None,
            )
            .await
            .unwrap();
        assert_eq!(drafts.len(), 3);

        for table in ["records", "assets", "asset_snapshots", "subscriptions"] {
            let count: i64 = sqlx::query_scalar(&format!(
                "SELECT COUNT(*) FROM {table} WHERE profile_id = ?1"
            ))
            .bind(profile)
            .fetch_one(repo.pool())
            .await
            .unwrap();
            assert_eq!(count, 0, "{table} changed before confirmation");
        }
    }

    #[tokio::test]
    async fn confirming_all_draft_kinds_is_atomic() {
        let repo = make_repo().await;
        let profile = "confirm-all-kinds";
        let mut subscription_payload = record_payload(28.0);
        subscription_payload.category = Some("订阅".to_string());
        subscription_payload.subscription_cycle = Some(SubscriptionCycle::Monthly);
        let asset_payload = ParsedRecordPayload {
            direction: None,
            amount: None,
            currency: None,
            category: None,
            merchant: None,
            transaction_at: None,
            note: None,
            subscription_cycle: None,
            asset_info: Some(ParsedAssetInfo {
                name: "测试银行".to_string(),
                category: Some("存款".to_string()),
                amount: 10_000.0,
                currency: Some("CNY".to_string()),
                recorded_on: Some("2026-07-14".to_string()),
                note: Some("月底余额".to_string()),
            }),
        };
        let drafts = repo
            .create_parsed_drafts_batch(
                profile,
                "原始输入",
                &[record_payload(18.0), asset_payload, subscription_payload],
                ParserSource::Local,
                None,
            )
            .await
            .unwrap();
        let subscription_record = RecordCreate {
            category: "订阅".to_string(),
            amount: 28.0,
            ..record_create(28.0)
        };
        repo.confirm_parsed_drafts(
            profile,
            "device-test",
            vec![
                (
                    drafts[0].id,
                    ParsedDraftConfirmationAction::Record(record_create(18.0)),
                ),
                (
                    drafts[1].id,
                    ParsedDraftConfirmationAction::Asset(AssetConfirmationCreate {
                        name: "测试银行".to_string(),
                        category: "存款".to_string(),
                        amount: 10_000.0,
                        currency: "CNY".to_string(),
                        recorded_on: NaiveDate::from_ymd_opt(2026, 7, 14).unwrap(),
                        note: Some("月底余额".to_string()),
                    }),
                ),
                (
                    drafts[2].id,
                    ParsedDraftConfirmationAction::Subscription {
                        record: subscription_record,
                        subscription: SubscriptionCreate {
                            direction: RecordDirection::Expense,
                            amount: 28.0,
                            currency: "CNY".to_string(),
                            category: "订阅".to_string(),
                            merchant: Some("测试商户".to_string()),
                            note: None,
                            cycle: SubscriptionCycle::Monthly,
                            anchor_day: 14,
                            anchor_month: None,
                            next_due_at: NaiveDate::from_ymd_opt(2026, 8, 14).unwrap(),
                        },
                    },
                ),
            ],
            "已确认三类草稿。",
        )
        .await
        .unwrap();

        for (table, expected) in [
            ("records", 2_i64),
            ("assets", 1),
            ("asset_snapshots", 1),
            ("subscriptions", 1),
        ] {
            let count: i64 = sqlx::query_scalar(&format!(
                "SELECT COUNT(*) FROM {table} WHERE profile_id = ?1"
            ))
            .bind(profile)
            .fetch_one(repo.pool())
            .await
            .unwrap();
            assert_eq!(count, expected, "unexpected {table} count");
        }
        assert!(
            repo.list_active_record_drafts(profile)
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn confirmation_failure_rolls_back_earlier_actions() {
        let repo = make_repo().await;
        let profile = "confirm-rollback";
        let drafts = repo
            .create_parsed_drafts_batch(
                profile,
                "两笔账单",
                &[record_payload(10.0), record_payload(20.0)],
                ParserSource::Local,
                None,
            )
            .await
            .unwrap();
        let error = repo
            .confirm_parsed_drafts(
                profile,
                "device-test",
                vec![
                    (
                        drafts[0].id,
                        ParsedDraftConfirmationAction::Record(record_create(10.0)),
                    ),
                    (
                        drafts[1].id,
                        ParsedDraftConfirmationAction::Asset(AssetConfirmationCreate {
                            name: "错误动作".to_string(),
                            category: "存款".to_string(),
                            amount: 20.0,
                            currency: "CNY".to_string(),
                            recorded_on: NaiveDate::from_ymd_opt(2026, 7, 14).unwrap(),
                            note: None,
                        }),
                    ),
                ],
                "不应写入",
            )
            .await
            .unwrap_err();
        assert!(error.to_string().contains("kind does not match"));

        let record_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM records WHERE profile_id = ?1")
                .bind(profile)
                .fetch_one(repo.pool())
                .await
                .unwrap();
        assert_eq!(record_count, 0);
        assert_eq!(
            repo.list_active_record_drafts(profile).await.unwrap().len(),
            2
        );
    }

    #[tokio::test]
    async fn record_insert_failure_rolls_back_confirmation() {
        assert_injected_confirmation_failure_rolls_back(
            "record-insert-failure",
            "CREATE TRIGGER fail_record BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'injected failure: record'); END;",
            record_payload(10.0),
            ParsedDraftConfirmationAction::Record(record_create(10.0)),
        )
        .await;
    }

    #[tokio::test]
    async fn asset_snapshot_failure_rolls_back_asset_and_confirmation() {
        assert_injected_confirmation_failure_rolls_back(
            "asset-snapshot-failure",
            "CREATE TRIGGER fail_snapshot BEFORE INSERT ON asset_snapshots BEGIN SELECT RAISE(ABORT, 'injected failure: snapshot'); END;",
            asset_payload(),
            asset_action(),
        )
        .await;
    }

    #[tokio::test]
    async fn subscription_record_failure_rolls_back_subscription_and_confirmation() {
        assert_injected_confirmation_failure_rolls_back(
            "subscription-record-failure",
            "CREATE TRIGGER fail_subscription_record BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'injected failure: subscription record'); END;",
            subscription_payload(),
            subscription_action(),
        )
        .await;
    }

    #[tokio::test]
    async fn draft_status_failure_rolls_back_business_write_and_confirmation() {
        assert_injected_confirmation_failure_rolls_back(
            "draft-status-failure",
            "CREATE TRIGGER fail_draft_status BEFORE UPDATE OF status ON parsed_drafts WHEN NEW.status = 'confirmed' BEGIN SELECT RAISE(ABORT, 'injected failure: draft status'); END;",
            record_payload(10.0),
            ParsedDraftConfirmationAction::Record(record_create(10.0)),
        )
        .await;
    }

    #[tokio::test]
    async fn confirmation_rejects_cross_profile_draft_without_writes() {
        let repo = make_repo().await;
        let draft = repo
            .create_parsed_drafts_batch(
                "profile-a",
                "一笔账单",
                &[record_payload(10.0)],
                ParserSource::Local,
                None,
            )
            .await
            .unwrap()
            .remove(0);

        let error = repo
            .confirm_parsed_drafts(
                "profile-b",
                "device-test",
                vec![(
                    draft.id,
                    ParsedDraftConfirmationAction::Record(record_create(10.0)),
                )],
                "不应写入",
            )
            .await
            .unwrap_err();

        assert!(error.to_string().contains("not found for profile"));
        let record_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM records")
            .fetch_one(repo.pool())
            .await
            .unwrap();
        assert_eq!(record_count, 0);
        assert_eq!(
            repo.list_active_record_drafts("profile-a")
                .await
                .unwrap()
                .len(),
            1
        );
    }

    #[tokio::test]
    async fn duplicate_confirmation_action_rolls_back_the_batch() {
        let repo = make_repo().await;
        let profile = "duplicate-confirmation";
        let draft = repo
            .create_parsed_drafts_batch(
                profile,
                "一笔账单",
                &[record_payload(10.0)],
                ParserSource::Local,
                None,
            )
            .await
            .unwrap()
            .remove(0);

        let error = repo
            .confirm_parsed_drafts(
                profile,
                "device-test",
                vec![
                    (
                        draft.id,
                        ParsedDraftConfirmationAction::Record(record_create(10.0)),
                    ),
                    (
                        draft.id,
                        ParsedDraftConfirmationAction::Record(record_create(10.0)),
                    ),
                ],
                "不应写入",
            )
            .await
            .unwrap_err();

        assert!(error.to_string().contains("not confirmable"));
        let record_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM records WHERE profile_id = ?1")
                .bind(profile)
                .fetch_one(repo.pool())
                .await
                .unwrap();
        assert_eq!(record_count, 0);
        assert_eq!(
            repo.list_active_record_drafts(profile).await.unwrap().len(),
            1
        );
    }

    #[tokio::test]
    async fn parsed_draft_migration_preserves_ids_statuses_and_confirmations() {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        for migration in [
            include_str!("../../../migrations/0001_init.sql"),
            include_str!("../../../migrations/0002_seed_sync_state.sql"),
            include_str!("../../../migrations/0003_add_fx_rates.sql"),
            include_str!("../../../migrations/0004_add_subscriptions.sql"),
            include_str!("../../../migrations/0005_add_assets.sql"),
            include_str!("../../../migrations/0006_add_app_settings.sql"),
            include_str!("../../../migrations/0007_sync_scaffolding.sql"),
            include_str!("../../../migrations/0008_synced_version.sql"),
            include_str!("../../../migrations/0009_drop_sync_outbox.sql"),
        ] {
            sqlx::raw_sql(migration).execute(&pool).await.unwrap();
        }

        for (id, status, confirmed_record_id) in [
            ("draft-parsed", "parsed", None),
            (
                "draft-confirmed",
                "confirmed",
                Some("00000000-0000-0000-0000-000000000001"),
            ),
            ("draft-discarded", "discarded", None),
        ] {
            sqlx::query(
                r#"
                INSERT INTO record_drafts (
                    id, profile_id, content, status, confirmed_record_id,
                    direction, amount, currency, category, merchant,
                    transaction_at, note
                ) VALUES (?1, 'migration-profile', '原始输入', ?2, ?3,
                    'expense', 12.5, 'CNY', '餐饮', '测试商户',
                    '2026-07-14T12:00:00Z', '测试')
                "#,
            )
            .bind(id)
            .bind(status)
            .bind(confirmed_record_id)
            .execute(&pool)
            .await
            .unwrap();
        }
        sqlx::query(
            "INSERT INTO conversation_messages (id, profile_id, role, content, draft_id) VALUES ('message-1', 'migration-profile', 'assistant', '待确认', 'draft-parsed')",
        )
        .execute(&pool)
        .await
        .unwrap();

        let mut transaction = pool.begin().await.unwrap();
        sqlx::raw_sql(include_str!(
            "../../../migrations/0010_generalize_parsed_drafts.sql"
        ))
        .execute(&mut *transaction)
        .await
        .unwrap();
        transaction.commit().await.unwrap();

        let rows = sqlx::query(
            "SELECT id, status, parser_source, payload_json, confirmation_json FROM parsed_drafts ORDER BY id",
        )
        .fetch_all(&pool)
        .await
        .unwrap();
        assert_eq!(rows.len(), 3);
        for row in &rows {
            assert_eq!(row.get::<String, _>("parser_source"), "cloud");
            let payload: ParsedRecordPayload =
                serde_json::from_str(&row.get::<String, _>("payload_json")).unwrap();
            assert_eq!(payload.amount, Some(12.5));
            assert_eq!(payload.currency.as_deref(), Some("CNY"));
        }
        let confirmed = rows
            .iter()
            .find(|row| row.get::<String, _>("id") == "draft-confirmed")
            .unwrap();
        assert_eq!(confirmed.get::<String, _>("status"), "confirmed");
        let confirmation: ParsedDraftConfirmation =
            serde_json::from_str(&confirmed.get::<String, _>("confirmation_json")).unwrap();
        assert_eq!(
            confirmation.record_id,
            Some(Uuid::parse_str("00000000-0000-0000-0000-000000000001").unwrap())
        );
        let linked_draft: String =
            sqlx::query_scalar("SELECT draft_id FROM conversation_messages WHERE id = 'message-1'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(linked_draft, "draft-parsed");
    }

    #[tokio::test]
    async fn migrations_create_sync_state_without_outbox() {
        let db_path =
            std::env::temp_dir().join(format!("billlens-apple-db-{}.sqlite", Uuid::new_v4()));
        let repo = BillRepository::connect(&db_path).await.unwrap();
        repo.ensure_sync_state("test-profile").await.unwrap();
        let row = sqlx::query("SELECT COUNT(*) AS count FROM sync_state WHERE profile_id = ?1")
            .bind("test-profile")
            .fetch_one(repo.pool())
            .await
            .unwrap();
        assert_eq!(row.get::<i64, _>("count"), 1);
    }

    #[tokio::test]
    async fn create_record_is_pending_sync() {
        let db_path =
            std::env::temp_dir().join(format!("billlens-apple-db-{}.sqlite", Uuid::new_v4()));
        let repo = BillRepository::connect(&db_path).await.unwrap();
        let _ = repo
            .create_record(
                Uuid::new_v4(),
                "test-profile",
                "device-a",
                RecordCreate {
                    direction: RecordDirection::Expense,
                    amount: 30.0,
                    currency: "CNY".to_string(),
                    category: "交通".to_string(),
                    merchant: Some("滴滴".to_string()),
                    transaction_at: Utc::now(),
                    note: Some("测试".to_string()),
                },
            )
            .await
            .unwrap();

        assert_eq!(repo.pending_sync_count("test-profile").await.unwrap(), 1);
    }

    #[tokio::test]
    async fn upsert_fx_rate_persists_latest_cache() {
        let db_path =
            std::env::temp_dir().join(format!("billlens-apple-db-{}.sqlite", Uuid::new_v4()));
        let repo = BillRepository::connect(&db_path).await.unwrap();
        let fetched_at = Utc::now();
        let rate_date = NaiveDate::from_ymd_opt(2026, 4, 10).unwrap();

        repo.upsert_fx_rate("USD", "CNY", 6.83, rate_date, fetched_at)
            .await
            .unwrap();

        let cached = repo.latest_fx_rate("USD", "CNY").await.unwrap().unwrap();
        assert_eq!(cached.base_currency, "USD");
        assert_eq!(cached.quote_currency, "CNY");
        assert_eq!(cached.rate, 6.83);
        assert_eq!(cached.rate_date, rate_date);
    }

    #[tokio::test]
    async fn subscription_crud_lifecycle() {
        let db_path =
            std::env::temp_dir().join(format!("billlens-apple-db-{}.sqlite", Uuid::new_v4()));
        let repo = BillRepository::connect(&db_path).await.unwrap();
        let profile = "test-profile";
        let sub_id = Uuid::new_v4();

        // Create
        let sub = repo
            .create_subscription(
                sub_id,
                profile,
                "device-a",
                SubscriptionCreate {
                    direction: RecordDirection::Expense,
                    amount: 10.0,
                    currency: "USD".to_string(),
                    category: "订阅".to_string(),
                    merchant: Some("GitHub Copilot".to_string()),
                    note: None,
                    cycle: SubscriptionCycle::Monthly,
                    anchor_day: 16,
                    anchor_month: None,
                    next_due_at: NaiveDate::from_ymd_opt(2026, 5, 16).unwrap(),
                },
            )
            .await
            .unwrap();
        assert_eq!(sub.amount, 10.0);
        assert!(sub.is_active);
        assert_eq!(sub.cycle, SubscriptionCycle::Monthly);

        // List
        let subs = repo.list_subscriptions(profile).await.unwrap();
        assert_eq!(subs.len(), 1);

        // Pause
        let paused = repo.pause_subscription(sub_id, profile).await.unwrap();
        assert!(!paused.is_active);

        // Resume
        let resumed = repo.resume_subscription(sub_id, profile).await.unwrap();
        assert!(resumed.is_active);

        // Update
        let updated = repo
            .update_subscription(
                sub_id,
                profile,
                SubscriptionUpdate {
                    amount: Some(15.0),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(updated.amount, 15.0);

        // Soft delete
        repo.soft_delete_subscription(sub_id, profile)
            .await
            .unwrap();
        let subs_after = repo.list_subscriptions(profile).await.unwrap();
        assert!(subs_after.is_empty());
    }

    #[tokio::test]
    async fn list_active_due_subscriptions_filters_correctly() {
        let db_path =
            std::env::temp_dir().join(format!("billlens-apple-db-{}.sqlite", Uuid::new_v4()));
        let repo = BillRepository::connect(&db_path).await.unwrap();
        let profile = "test-profile";

        // Create a due subscription (next_due_at in the past)
        repo.create_subscription(
            Uuid::new_v4(),
            profile,
            "device-a",
            SubscriptionCreate {
                direction: RecordDirection::Expense,
                amount: 10.0,
                currency: "USD".to_string(),
                category: "订阅".to_string(),
                merchant: Some("Netflix".to_string()),
                note: None,
                cycle: SubscriptionCycle::Monthly,
                anchor_day: 1,
                anchor_month: None,
                next_due_at: NaiveDate::from_ymd_opt(2026, 4, 1).unwrap(),
            },
        )
        .await
        .unwrap();

        // Create a future subscription (not due yet)
        repo.create_subscription(
            Uuid::new_v4(),
            profile,
            "device-a",
            SubscriptionCreate {
                direction: RecordDirection::Expense,
                amount: 20.0,
                currency: "CNY".to_string(),
                category: "订阅".to_string(),
                merchant: Some("iCloud".to_string()),
                note: None,
                cycle: SubscriptionCycle::Monthly,
                anchor_day: 1,
                anchor_month: None,
                next_due_at: NaiveDate::from_ymd_opt(2099, 1, 1).unwrap(),
            },
        )
        .await
        .unwrap();

        let due = repo
            .list_active_due_subscriptions(profile, "2026-04-16")
            .await
            .unwrap();
        assert_eq!(due.len(), 1);
        assert_eq!(due[0].merchant.as_deref(), Some("Netflix"));
    }

    // ── Sync tests ──────────────────────────────────────────────────────────

    async fn make_repo() -> BillRepository {
        let db_path =
            std::env::temp_dir().join(format!("billlens-sync-test-{}.sqlite", Uuid::new_v4()));
        BillRepository::connect(&db_path).await.unwrap()
    }

    fn base_record(_profile: &str, _device: &str) -> (Uuid, RecordCreate) {
        (
            Uuid::new_v4(),
            RecordCreate {
                direction: RecordDirection::Expense,
                amount: 100.0,
                currency: "CNY".to_string(),
                category: "餐饮".to_string(),
                merchant: Some("测试".to_string()),
                transaction_at: Utc::now(),
                note: None,
            },
        )
    }

    // write → record has sync_version > synced_version and appears in list_dirty
    #[tokio::test]
    async fn write_sets_sync_watermark_dirty_and_appears_in_dirty_list() {
        let repo = make_repo().await;
        let profile = "p1";
        let (id, create) = base_record(profile, "dev-a");
        repo.create_record(id, profile, "dev-a", create)
            .await
            .unwrap();

        let dirty = repo.list_dirty_records(profile, 10).await.unwrap();
        assert_eq!(dirty.len(), 1);
        assert_eq!(dirty[0].id, id);
        assert!(dirty[0].sync_version > dirty[0].synced_version);
    }

    // mark_synced with matching version → synced_version catches up, leaves dirty list
    #[tokio::test]
    async fn mark_synced_clears_flag_when_version_matches() {
        let repo = make_repo().await;
        let profile = "p1";
        let (id, create) = base_record(profile, "dev-a");
        let record = repo
            .create_record(id, profile, "dev-a", create)
            .await
            .unwrap();

        repo.mark_record_synced(id, record.sync_version)
            .await
            .unwrap();

        let dirty = repo.list_dirty_records(profile, 10).await.unwrap();
        assert!(dirty.is_empty(), "should be gone from dirty list");
    }

    // mark_synced with stale version (record was mutated between push and ack) → flag stays
    #[tokio::test]
    async fn mark_synced_rejects_stale_version() {
        let repo = make_repo().await;
        let profile = "p1";
        let (id, create) = base_record(profile, "dev-a");
        let record = repo
            .create_record(id, profile, "dev-a", create)
            .await
            .unwrap();
        // mutate → sync_version bumps
        repo.update_record(
            id,
            profile,
            RecordUpdate {
                direction: RecordDirection::Expense,
                amount: 200.0,
                currency: "CNY".to_string(),
                category: "餐饮".to_string(),
                merchant: None,
                transaction_at: Utc::now(),
                note: None,
            },
        )
        .await
        .unwrap();

        // ack with the old version — should be a no-op
        repo.mark_record_synced(id, record.sync_version)
            .await
            .unwrap();

        let dirty = repo.list_dirty_records(profile, 10).await.unwrap();
        assert_eq!(dirty.len(), 1, "should still be dirty after stale ack");
        assert_eq!(dirty[0].sync_version, record.sync_version + 1);
    }

    // remote with higher version overwrites local
    #[tokio::test]
    async fn apply_remote_lww_high_version_wins() {
        let repo = make_repo().await;
        let profile = "p1";
        let (id, create) = base_record(profile, "dev-a");
        let local = repo
            .create_record(id, profile, "dev-a", create)
            .await
            .unwrap();

        let remote = Record {
            sync_version: local.sync_version + 5,
            amount: 999.0,
            updated_at: local.updated_at + chrono::Duration::seconds(1),
            ..local.clone()
        };
        let applied = repo.apply_remote_record(remote).await.unwrap();
        assert!(applied);

        let row = repo.get_record(id, profile).await.unwrap();
        assert_eq!(row.amount, 999.0);
        assert_eq!(row.sync_version, local.sync_version + 5);
        assert_eq!(
            row.synced_version, row.sync_version,
            "applied remote must advance synced_version"
        );
    }

    // remote with lower version is ignored
    #[tokio::test]
    async fn apply_remote_lww_stale_remote_is_ignored() {
        let repo = make_repo().await;
        let profile = "p1";
        let (id, create) = base_record(profile, "dev-a");
        let local = repo
            .create_record(id, profile, "dev-a", create)
            .await
            .unwrap();
        // bump local to version 3
        for _ in 0..2 {
            repo.update_record(
                id,
                profile,
                RecordUpdate {
                    direction: RecordDirection::Expense,
                    amount: 50.0,
                    currency: "CNY".to_string(),
                    category: "餐饮".to_string(),
                    merchant: None,
                    transaction_at: Utc::now(),
                    note: None,
                },
            )
            .await
            .unwrap();
        }

        let remote = Record {
            sync_version: 1, // stale
            amount: 1.0,
            updated_at: local.updated_at - chrono::Duration::seconds(10),
            ..local.clone()
        };
        let applied = repo.apply_remote_record(remote).await.unwrap();
        assert!(!applied, "stale remote should not be applied");

        let row = repo.get_record(id, profile).await.unwrap();
        assert_eq!(row.amount, 50.0, "local value must be preserved");
    }

    // same version, later updated_at wins
    #[tokio::test]
    async fn apply_remote_lww_same_version_later_timestamp_wins() {
        let repo = make_repo().await;
        let profile = "p1";
        let (id, create) = base_record(profile, "dev-a");
        let local = repo
            .create_record(id, profile, "dev-a", create)
            .await
            .unwrap();

        let remote = Record {
            sync_version: local.sync_version, // same version
            amount: 777.0,
            updated_at: local.updated_at + chrono::Duration::seconds(60),
            ..local.clone()
        };
        let applied = repo.apply_remote_record(remote).await.unwrap();
        assert!(applied);

        let row = repo.get_record(id, profile).await.unwrap();
        assert_eq!(row.amount, 777.0);
    }

    // tombstone: apply_remote with deleted_at propagates soft-delete
    #[tokio::test]
    async fn apply_remote_tombstone_soft_deletes_local() {
        let repo = make_repo().await;
        let profile = "p1";
        let (id, create) = base_record(profile, "dev-a");
        let local = repo
            .create_record(id, profile, "dev-a", create)
            .await
            .unwrap();

        let deleted_at = Utc::now();
        let remote = Record {
            sync_version: local.sync_version + 1,
            deleted_at: Some(deleted_at),
            updated_at: local.updated_at + chrono::Duration::seconds(1),
            ..local.clone()
        };
        let applied = repo.apply_remote_record(remote).await.unwrap();
        assert!(applied);

        // get_record filters deleted_at IS NULL, should 404
        let result = repo.get_record(id, profile).await;
        assert!(result.is_err(), "soft-deleted record should not be visible");
    }

    // list_dirty respects limit
    #[tokio::test]
    async fn list_dirty_respects_limit() {
        let repo = make_repo().await;
        let profile = "p1";
        for _ in 0..5 {
            let (id, create) = base_record(profile, "dev-a");
            repo.create_record(id, profile, "dev-a", create)
                .await
                .unwrap();
        }
        let dirty = repo.list_dirty_records(profile, 3).await.unwrap();
        assert_eq!(dirty.len(), 3);
    }

    // cursor round-trip: set → get returns same token
    #[tokio::test]
    async fn cursor_roundtrip_set_and_get() {
        let repo = make_repo().await;
        let profile = "p1";
        let zone = "BillLensZone";

        let initial = repo.get_sync_cursor(profile, zone).await.unwrap();
        assert!(initial.is_none());

        repo.set_sync_cursor(profile, zone, Some("tok_abc123"))
            .await
            .unwrap();
        let got = repo.get_sync_cursor(profile, zone).await.unwrap();
        assert_eq!(got.as_deref(), Some("tok_abc123"));

        repo.set_sync_cursor(profile, zone, None).await.unwrap();
        let cleared = repo.get_sync_cursor(profile, zone).await.unwrap();
        assert!(cleared.is_none());
    }

    // apply_remote on brand-new id inserts the row (first-sync on new device)
    #[tokio::test]
    async fn apply_remote_inserts_new_record() {
        let repo = make_repo().await;
        let profile = "p1";
        let id = Uuid::new_v4();
        let now = Utc::now();
        let remote = Record {
            id,
            profile_id: profile.to_string(),
            direction: RecordDirection::Income,
            amount: 500.0,
            currency: "CNY".to_string(),
            category: "工资收入".to_string(),
            merchant: None,
            transaction_at: now,
            note: None,
            device_id: "dev-b".to_string(),
            sync_version: 3,
            synced_version: 3,
            deleted_at: None,
            created_at: now,
            updated_at: now,
        };
        let applied = repo.apply_remote_record(remote).await.unwrap();
        assert!(applied);

        let row = repo.get_record(id, profile).await.unwrap();
        assert_eq!(row.amount, 500.0);
        assert_eq!(row.sync_version, 3);
        assert_eq!(row.synced_version, 3);
    }

    // subscription sync: create marks dirty, apply_remote LWW works
    #[tokio::test]
    async fn subscription_sync_dirty_and_apply_remote() {
        let repo = make_repo().await;
        let profile = "p1";
        let sub_id = Uuid::new_v4();
        let sub = repo
            .create_subscription(
                sub_id,
                profile,
                "dev-a",
                SubscriptionCreate {
                    direction: RecordDirection::Expense,
                    amount: 30.0,
                    currency: "USD".to_string(),
                    category: "订阅".to_string(),
                    merchant: Some("Spotify".to_string()),
                    note: None,
                    cycle: SubscriptionCycle::Monthly,
                    anchor_day: 1,
                    anchor_month: None,
                    next_due_at: NaiveDate::from_ymd_opt(2026, 5, 1).unwrap(),
                },
            )
            .await
            .unwrap();

        let dirty = repo.list_dirty_subscriptions(profile, 10).await.unwrap();
        assert_eq!(dirty.len(), 1);

        repo.mark_subscription_synced(sub_id, sub.sync_version)
            .await
            .unwrap();
        assert!(
            repo.list_dirty_subscriptions(profile, 10)
                .await
                .unwrap()
                .is_empty()
        );

        // remote with higher version changes amount
        let remote = Subscription {
            amount: 35.0,
            sync_version: sub.sync_version + 1,
            updated_at: sub.updated_at + chrono::Duration::seconds(1),
            ..sub
        };
        let applied = repo.apply_remote_subscription(remote).await.unwrap();
        assert!(applied);
        let updated = repo.get_subscription(sub_id, profile).await.unwrap();
        assert_eq!(updated.amount, 35.0);
    }

    // app_setting sync: set_setting → dirty → apply_remote LWW
    #[tokio::test]
    async fn setting_sync_dirty_and_apply_remote() {
        let repo = make_repo().await;
        repo.set_setting_with_device("theme", "dark", "dev-a")
            .await
            .unwrap();

        let dirty = repo.list_dirty_settings(10).await.unwrap();
        assert_eq!(dirty.len(), 1);
        assert_eq!(dirty[0].value, "dark");

        repo.mark_setting_synced("theme", dirty[0].sync_version)
            .await
            .unwrap();
        assert!(repo.list_dirty_settings(10).await.unwrap().is_empty());

        // remote with higher version
        let remote = AppSetting {
            key: "theme".to_string(),
            value: "light".to_string(),
            sync_version: dirty[0].sync_version + 1,
            synced_version: dirty[0].sync_version + 1,
            deleted_at: None,
            device_id: "dev-b".to_string(),
            updated_at: Utc::now() + chrono::Duration::seconds(10),
        };
        let applied = repo.apply_remote_setting(remote).await.unwrap();
        assert!(applied);
        let val = repo.get_setting("theme").await.unwrap();
        assert_eq!(val.as_deref(), Some("light"));
    }
}
