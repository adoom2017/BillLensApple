mod models;

use anyhow::{Context, Result, anyhow};
use chrono::{DateTime, NaiveDate, Utc};
pub use models::*;
use sqlx::{
    FromRow, QueryBuilder, Row, Sqlite, SqlitePool,
    sqlite::{SqliteConnectOptions, SqlitePoolOptions},
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

        let record = row.try_into()?;
        self.enqueue_sync_event(profile_id, &record, "create")
            .await?;
        Ok(record)
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
                needs_sync = 1,
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

        let record = row.try_into()?;
        self.enqueue_sync_event(profile_id, &record, "update")
            .await?;
        Ok(record)
    }

    pub async fn soft_delete_record(&self, id: Uuid, profile_id: &str) -> Result<Record> {
        let row = sqlx::query_as::<_, RecordRow>(
            r#"
            UPDATE records
            SET deleted_at = CURRENT_TIMESTAMP,
                sync_version = sync_version + 1,
                needs_sync = 1,
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

        let record = row.try_into()?;
        self.enqueue_sync_event(profile_id, &record, "delete")
            .await?;
        Ok(record)
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

    pub async fn create_record_draft(
        &self,
        id: Uuid,
        profile_id: &str,
        content: &str,
        auto_confirm: bool,
        parsed: &ParsedRecordPayload,
    ) -> Result<RecordDraft> {
        let row = sqlx::query_as::<_, RecordDraftRow>(
            r#"
            INSERT INTO record_drafts (
                id, profile_id, content, auto_confirm, status, direction, amount, currency, category, merchant, transaction_at, note
            )
            VALUES (?1, ?2, ?3, ?4, 'parsed', ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            RETURNING *
            "#,
        )
        .bind(id.to_string())
        .bind(profile_id)
        .bind(content)
        .bind(auto_confirm)
        .bind(parsed.direction.as_ref().map(|value| value.as_str()))
        .bind(parsed.amount)
        .bind(parsed.currency.clone())
        .bind(parsed.category.clone())
        .bind(parsed.merchant.clone())
        .bind(parsed.transaction_at)
        .bind(parsed.note.clone())
        .fetch_one(&self.pool)
        .await
        .context("failed to insert record draft")?;

        row.try_into()
    }

    pub async fn get_record_draft(&self, id: Uuid) -> Result<RecordDraft> {
        let row = sqlx::query_as::<_, RecordDraftRow>("SELECT * FROM record_drafts WHERE id = ?1")
            .bind(id.to_string())
            .fetch_optional(&self.pool)
            .await
            .context("failed to load record draft")?
            .ok_or_else(|| anyhow!("record draft not found"))?;

        row.try_into()
    }

    pub async fn update_record_draft(
        &self,
        id: Uuid,
        update: RecordDraftUpdate,
    ) -> Result<RecordDraft> {
        let row = sqlx::query_as::<_, RecordDraftRow>(
            r#"
            UPDATE record_drafts
            SET direction = ?2,
                amount = ?3,
                currency = ?4,
                category = ?5,
                merchant = ?6,
                transaction_at = ?7,
                note = ?8,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = ?1
            RETURNING *
            "#,
        )
        .bind(id.to_string())
        .bind(update.direction.as_ref().map(|value| value.as_str()))
        .bind(update.amount)
        .bind(update.currency)
        .bind(update.category)
        .bind(update.merchant)
        .bind(update.transaction_at)
        .bind(update.note)
        .fetch_one(&self.pool)
        .await
        .context("failed to update record draft")?;

        row.try_into()
    }

    pub async fn latest_active_record_draft(
        &self,
        profile_id: &str,
    ) -> Result<Option<RecordDraft>> {
        let row = sqlx::query_as::<_, RecordDraftRow>(
            r#"
            SELECT * FROM record_drafts
            WHERE profile_id = ?1 AND status = 'parsed'
            ORDER BY updated_at DESC
            LIMIT 1
            "#,
        )
        .bind(profile_id)
        .fetch_optional(&self.pool)
        .await
        .context("failed to load latest active record draft")?;

        row.map(TryInto::try_into).transpose()
    }

    pub async fn list_active_record_drafts(&self, profile_id: &str) -> Result<Vec<RecordDraft>> {
        let rows = sqlx::query_as::<_, RecordDraftRow>(
            r#"
            SELECT * FROM record_drafts
            WHERE profile_id = ?1 AND status = 'parsed'
            ORDER BY created_at ASC, rowid ASC
            "#,
        )
        .bind(profile_id)
        .fetch_all(&self.pool)
        .await
        .context("failed to list active record drafts")?;

        rows.into_iter().map(TryInto::try_into).collect()
    }

    /// Insert multiple draft rows inside a single transaction so a mid-batch
    /// failure never leaves a partial set of rows committed.
    pub async fn create_record_drafts_batch(
        &self,
        profile_id: &str,
        content: &str,
        payloads: &[ParsedRecordPayload],
    ) -> Result<Vec<RecordDraft>> {
        let mut tx = self
            .pool
            .begin()
            .await
            .context("failed to begin draft batch transaction")?;
        let mut drafts = Vec::with_capacity(payloads.len());
        for parsed in payloads {
            let id = Uuid::new_v4();
            let row = sqlx::query_as::<_, RecordDraftRow>(
                r#"
                INSERT INTO record_drafts (
                    id, profile_id, content, auto_confirm, status, direction, amount, currency, category, merchant, transaction_at, note
                )
                VALUES (?1, ?2, ?3, false, 'parsed', ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                RETURNING *
                "#,
            )
            .bind(id.to_string())
            .bind(profile_id)
            .bind(content)
            .bind(parsed.direction.as_ref().map(|v| v.as_str()))
            .bind(parsed.amount)
            .bind(parsed.currency.clone())
            .bind(parsed.category.clone())
            .bind(parsed.merchant.clone())
            .bind(parsed.transaction_at)
            .bind(parsed.note.clone())
            .fetch_one(&mut *tx)
            .await
            .context("failed to insert record draft in batch")?;
            drafts.push(row.try_into()?);
        }
        tx.commit()
            .await
            .context("failed to commit draft batch transaction")?;
        Ok(drafts)
    }

    /// Confirm multiple drafts and insert their records in a single transaction.
    pub async fn confirm_record_drafts_batch(
        &self,
        profile_id: &str,
        device_id: &str,
        draft_creates: Vec<(Uuid, RecordCreate)>,
    ) -> Result<Option<Record>> {
        let mut tx = self
            .pool
            .begin()
            .await
            .context("failed to begin confirm batch transaction")?;
        let mut last_record: Option<Record> = None;
        for (draft_id, create) in draft_creates {
            let record_id = Uuid::new_v4();
            let record_row = sqlx::query_as::<_, RecordRow>(
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
            .bind(create.direction.as_str())
            .bind(create.amount)
            .bind(create.currency)
            .bind(create.category)
            .bind(create.merchant)
            .bind(create.transaction_at)
            .bind(create.note)
            .bind(device_id)
            .fetch_one(&mut *tx)
            .await
            .context("failed to insert record in confirm batch")?;
            let record: Record = record_row.try_into()?;
            sqlx::query(
                r#"
                UPDATE record_drafts
                SET status = 'confirmed',
                    confirmed_record_id = ?2,
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = ?1
                "#,
            )
            .bind(draft_id.to_string())
            .bind(record_id.to_string())
            .execute(&mut *tx)
            .await
            .context("failed to mark draft confirmed in batch")?;
            let sync_payload = serde_json::to_string(&record)
                .context("failed to serialize sync payload in confirm batch")?;
            sqlx::query(
                r#"
                INSERT INTO sync_outbox (id, record_id, profile_id, operation, payload)
                VALUES (?1, ?2, ?3, 'create', ?4)
                "#,
            )
            .bind(Uuid::new_v4().to_string())
            .bind(record_id.to_string())
            .bind(profile_id)
            .bind(sync_payload)
            .execute(&mut *tx)
            .await
            .context("failed to enqueue sync event in confirm batch")?;
            last_record = Some(record);
        }
        tx.commit()
            .await
            .context("failed to commit confirm batch transaction")?;
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

    pub async fn mark_record_draft_confirmed(
        &self,
        draft_id: Uuid,
        record_id: Uuid,
    ) -> Result<RecordDraft> {
        let row = sqlx::query_as::<_, RecordDraftRow>(
            r#"
            UPDATE record_drafts
            SET status = 'confirmed',
                confirmed_record_id = ?2,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = ?1
            RETURNING *
            "#,
        )
        .bind(draft_id.to_string())
        .bind(record_id.to_string())
        .fetch_one(&self.pool)
        .await
        .context("failed to confirm record draft")?;

        row.try_into()
    }

    pub async fn discard_record_draft(&self, draft_id: Uuid) -> Result<RecordDraft> {
        let row = sqlx::query_as::<_, RecordDraftRow>(
            r#"
            UPDATE record_drafts
            SET status = 'discarded',
                updated_at = CURRENT_TIMESTAMP
            WHERE id = ?1
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

    /// NOTE: This method sums amounts directly without currency conversion.
    /// Results are inaccurate for multi-currency data. Prefer using
    /// `ledger()` which performs proper FX conversion via `aggregate_converted_stats`.
    #[deprecated(note = "does not handle multi-currency; use ledger() for accurate stats")]
    pub async fn record_stats(
        &self,
        profile_id: &str,
        range: RecordsStatsRange,
        direction: Option<RecordDirection>,
        category: Option<&str>,
    ) -> Result<RecordsStatsResponse> {
        let summary_rows = self
            .aggregate_summary_rows(profile_id, &range, direction.clone(), category)
            .await?;
        let category_rows = self
            .aggregate_category_rows(profile_id, &range, direction, category)
            .await?;

        let mut income_amount = 0.0;
        let mut income_count = 0;
        let mut expense_amount = 0.0;
        let mut expense_count = 0;

        for row in &summary_rows {
            match row.direction.as_str() {
                "income" => {
                    income_amount = row.total_amount;
                    income_count = row.record_count;
                }
                "expense" => {
                    expense_amount = row.total_amount;
                    expense_count = row.record_count;
                }
                _ => {}
            }
        }

        Ok(RecordsStatsResponse {
            range,
            summary: RecordsSummary {
                income_amount,
                income_count,
                expense_amount,
                expense_count,
                net_amount: income_amount - expense_amount,
            },
            by_direction: summary_rows
                .into_iter()
                .map(TryInto::try_into)
                .collect::<Result<Vec<_>>>()?,
            by_category: category_rows
                .into_iter()
                .map(TryInto::try_into)
                .collect::<Result<Vec<_>>>()?,
        })
    }

    async fn aggregate_summary_rows(
        &self,
        profile_id: &str,
        range: &RecordsStatsRange,
        direction: Option<RecordDirection>,
        category: Option<&str>,
    ) -> Result<Vec<DirectionStatsRow>> {
        let mut builder = QueryBuilder::<Sqlite>::new(
            "SELECT direction, COALESCE(SUM(amount), 0) AS total_amount, COUNT(*) AS record_count FROM records WHERE profile_id = ",
        );
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
        builder.push(" GROUP BY direction ORDER BY direction ASC");

        builder
            .build_query_as::<DirectionStatsRow>()
            .fetch_all(&self.pool)
            .await
            .context("failed to aggregate record summary")
    }

    async fn aggregate_category_rows(
        &self,
        profile_id: &str,
        range: &RecordsStatsRange,
        direction: Option<RecordDirection>,
        category: Option<&str>,
    ) -> Result<Vec<CategoryStatsRow>> {
        let mut builder = QueryBuilder::<Sqlite>::new(
            "SELECT category, direction, COALESCE(SUM(amount), 0) AS total_amount, COUNT(*) AS record_count FROM records WHERE profile_id = ",
        );
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
        builder.push(" GROUP BY category, direction ORDER BY total_amount DESC, category ASC");

        builder
            .build_query_as::<CategoryStatsRow>()
            .fetch_all(&self.pool)
            .await
            .context("failed to aggregate category stats")
    }

    // ── Subscription operations ─────────────────────────────────────────

    pub async fn create_subscription(
        &self,
        id: Uuid,
        profile_id: &str,
        input: SubscriptionCreate,
    ) -> Result<Subscription> {
        let row = sqlx::query_as::<_, SubscriptionRow>(
            r#"
            INSERT INTO subscriptions (
                id, profile_id, direction, amount, currency, category, merchant, note,
                cycle, anchor_day, anchor_month, next_due_at
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
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
                anchor_month = ?11, updated_at = datetime('now')
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

    pub async fn update_subscription_charged(
        &self,
        id: Uuid,
        last_charged_at: NaiveDate,
        next_due_at: NaiveDate,
    ) -> Result<()> {
        sqlx::query(
            r#"
            UPDATE subscriptions
            SET last_charged_at = ?2, next_due_at = ?3, updated_at = datetime('now')
            WHERE id = ?1
            "#,
        )
        .bind(id.to_string())
        .bind(last_charged_at.to_string())
        .bind(next_due_at.to_string())
        .execute(&self.pool)
        .await
        .context("failed to update subscription charged")?;
        Ok(())
    }

    /// Atomically create a record and update the subscription's charged state.
    /// Prevents duplicate records if the app crashes mid-cycle.
    pub async fn create_record_and_advance_subscription(
        &self,
        record_id: Uuid,
        profile_id: &str,
        device_id: &str,
        input: RecordCreate,
        subscription_id: Uuid,
        last_charged_at: NaiveDate,
        next_due_at: NaiveDate,
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
            SET last_charged_at = ?2, next_due_at = ?3, updated_at = datetime('now')
            WHERE id = ?1
            "#,
        )
        .bind(subscription_id.to_string())
        .bind(last_charged_at.to_string())
        .bind(next_due_at.to_string())
        .execute(&mut *tx)
        .await
        .context("failed to advance subscription in charge")?;

        tx.commit()
            .await
            .context("failed to commit subscription charge transaction")?;

        let record: Record = row.try_into()?;
        self.enqueue_sync_event(profile_id, &record, "create")
            .await?;
        Ok(record)
    }

    pub async fn pause_subscription(&self, id: Uuid, profile_id: &str) -> Result<Subscription> {
        let row = sqlx::query_as::<_, SubscriptionRow>(
            r#"
            UPDATE subscriptions
            SET is_active = 0, updated_at = datetime('now')
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
            SET is_active = 1, updated_at = datetime('now')
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
        let result = sqlx::query(
            r#"
            UPDATE subscriptions
            SET deleted_at = datetime('now'), is_active = 0, updated_at = datetime('now')
            WHERE id = ?1 AND profile_id = ?2 AND deleted_at IS NULL
            "#,
        )
        .bind(id.to_string())
        .bind(profile_id)
        .execute(&self.pool)
        .await
        .context("failed to delete subscription")?;

        if result.rows_affected() == 0 {
            return Err(anyhow!("subscription not found"));
        }
        Ok(())
    }

    // ── Asset operations ────────────────────────────────────────────────

    pub async fn find_or_create_asset(
        &self,
        profile_id: &str,
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
            INSERT INTO assets (id, profile_id, name, category, currency)
            VALUES (?1, ?2, ?3, ?4, ?5)
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
        recorded_on: &str,
        amount: f64,
        note: Option<&str>,
    ) -> Result<(AssetSnapshot, bool)> {
        let existing = sqlx::query_as::<_, AssetSnapshotRow>(
            r#"
            SELECT * FROM asset_snapshots
            WHERE asset_id = ?1 AND recorded_on = ?2
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
                SET amount = ?2, note = ?3, updated_at = datetime('now')
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
                INSERT INTO asset_snapshots (id, asset_id, profile_id, amount, recorded_on, note)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                RETURNING *
                "#,
            )
            .bind(id.to_string())
            .bind(asset_id.to_string())
            .bind(profile_id)
            .bind(amount)
            .bind(recorded_on)
            .bind(note)
            .fetch_one(&self.pool)
            .await
            .context("failed to insert asset snapshot")?
        };

        sqlx::query("UPDATE assets SET updated_at = datetime('now') WHERE id = ?1")
            .bind(asset_id.to_string())
            .execute(&self.pool)
            .await
            .context("failed to touch asset updated_at")?;

        Ok((row.try_into()?, created))
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
                WHERE asset_id = ?1
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

        results.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
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
            SET name = ?3, category = ?4, currency = ?5, note = ?6, updated_at = datetime('now')
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

    pub async fn soft_delete_asset(&self, id: Uuid, profile_id: &str) -> Result<()> {
        let result = sqlx::query(
            r#"
            UPDATE assets
            SET deleted_at = datetime('now'), updated_at = datetime('now')
            WHERE id = ?1 AND profile_id = ?2 AND deleted_at IS NULL
            "#,
        )
        .bind(id.to_string())
        .bind(profile_id)
        .execute(&self.pool)
        .await
        .context("failed to delete asset")?;

        if result.rows_affected() == 0 {
            return Err(anyhow!("asset not found"));
        }
        Ok(())
    }

    pub async fn delete_asset_snapshot(&self, snapshot_id: Uuid, profile_id: &str) -> Result<()> {
        let result = sqlx::query(
            "DELETE FROM asset_snapshots WHERE id = ?1 AND profile_id = ?2",
        )
        .bind(snapshot_id.to_string())
        .bind(profile_id)
        .execute(&self.pool)
        .await
        .context("failed to delete asset snapshot")?;

        if result.rows_affected() == 0 {
            return Err(anyhow!("asset snapshot not found"));
        }
        Ok(())
    }

    async fn enqueue_sync_event(
        &self,
        profile_id: &str,
        record: &Record,
        operation: &str,
    ) -> Result<()> {
        let payload = serde_json::to_string(record).context("failed to serialize sync payload")?;
        sqlx::query(
            r#"
            INSERT INTO sync_outbox (id, record_id, profile_id, operation, payload)
            VALUES (?1, ?2, ?3, ?4, ?5)
            "#,
        )
        .bind(Uuid::new_v4().to_string())
        .bind(record.id.to_string())
        .bind(profile_id)
        .bind(operation)
        .bind(payload)
        .execute(&self.pool)
        .await
        .context("failed to enqueue sync event")?;
        Ok(())
    }

    pub async fn pending_sync_count(&self, profile_id: &str) -> Result<i64> {
        let row = sqlx::query("SELECT COUNT(*) AS count FROM sync_outbox WHERE profile_id = ?1")
            .bind(profile_id)
            .fetch_one(&self.pool)
            .await
            .context("failed to count sync outbox")?;
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

    /// Remove sync_outbox entries older than the given number of days.
    /// Called during bootstrap to prevent unbounded growth while cloud sync
    /// is not yet implemented.
    pub async fn cleanup_old_sync_events(
        &self,
        profile_id: &str,
        max_age_days: i64,
    ) -> Result<u64> {
        let result = sqlx::query(
            r#"
            DELETE FROM sync_outbox
            WHERE profile_id = ?1
              AND created_at < datetime('now', ?2)
            "#,
        )
        .bind(profile_id)
        .bind(format!("-{max_age_days} days"))
        .execute(&self.pool)
        .await
        .context("failed to cleanup old sync events")?;
        Ok(result.rows_affected())
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
    deleted_at: Option<DateTime<Utc>>,
    needs_sync: i64,
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
            deleted_at: row.deleted_at,
            needs_sync: row.needs_sync != 0,
            created_at: row.created_at,
            updated_at: row.updated_at,
        })
    }
}

#[derive(Debug, FromRow)]
struct RecordDraftRow {
    id: String,
    profile_id: String,
    content: String,
    auto_confirm: i64,
    status: String,
    confirmed_record_id: Option<String>,
    direction: Option<String>,
    amount: Option<f64>,
    currency: Option<String>,
    category: Option<String>,
    merchant: Option<String>,
    transaction_at: Option<DateTime<Utc>>,
    note: Option<String>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl TryFrom<RecordDraftRow> for RecordDraft {
    type Error = anyhow::Error;

    fn try_from(row: RecordDraftRow) -> Result<Self> {
        Ok(Self {
            id: Uuid::parse_str(&row.id).context("invalid draft id")?,
            profile_id: row.profile_id,
            content: row.content,
            auto_confirm: row.auto_confirm != 0,
            status: RecordDraftStatus::try_from(row.status.as_str()).map_err(anyhow::Error::msg)?,
            confirmed_record_id: row
                .confirmed_record_id
                .map(|value| Uuid::parse_str(&value).context("invalid confirmed record id"))
                .transpose()?,
            direction: row
                .direction
                .map(|value| RecordDirection::try_from(value.as_str()).map_err(anyhow::Error::msg))
                .transpose()?,
            amount: row.amount,
            currency: row.currency,
            category: row.category,
            merchant: row.merchant,
            transaction_at: row.transaction_at,
            note: row.note,
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
struct DirectionStatsRow {
    direction: String,
    total_amount: f64,
    record_count: i64,
}

impl TryFrom<DirectionStatsRow> for DirectionStatsItem {
    type Error = anyhow::Error;

    fn try_from(row: DirectionStatsRow) -> Result<Self> {
        Ok(Self {
            direction: RecordDirection::try_from(row.direction.as_str())
                .map_err(anyhow::Error::msg)?,
            total_amount: row.total_amount,
            record_count: row.record_count,
        })
    }
}

#[derive(Debug, FromRow)]
struct CategoryStatsRow {
    category: String,
    direction: String,
    total_amount: f64,
    record_count: i64,
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

impl TryFrom<CategoryStatsRow> for CategoryStatsItem {
    type Error = anyhow::Error;

    fn try_from(row: CategoryStatsRow) -> Result<Self> {
        Ok(Self {
            category: row.category,
            direction: RecordDirection::try_from(row.direction.as_str())
                .map_err(anyhow::Error::msg)?,
            total_amount: row.total_amount,
            record_count: row.record_count,
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
            created_at: row.created_at,
            updated_at: row.updated_at,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn migrations_create_sync_outbox() {
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
    async fn create_record_enqueues_sync_event() {
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
}
