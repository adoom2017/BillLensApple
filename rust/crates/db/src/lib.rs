mod models;

use anyhow::{Context, Result, anyhow};
use chrono::{DateTime, Utc};
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
        self.enqueue_sync_event(profile_id, &record, "create").await?;
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
        self.enqueue_sync_event(profile_id, &record, "update").await?;
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
        self.enqueue_sync_event(profile_id, &record, "delete").await?;
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

    pub async fn latest_active_record_draft(&self, profile_id: &str) -> Result<Option<RecordDraft>> {
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

    pub async fn mark_record_draft_confirmed(&self, draft_id: Uuid, record_id: Uuid) -> Result<RecordDraft> {
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
        let mut builder = QueryBuilder::<Sqlite>::new(
            "SELECT * FROM records WHERE profile_id = ",
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
        builder.push(" ORDER BY transaction_at DESC, created_at DESC");

        let rows = builder
            .build_query_as::<RecordRow>()
            .fetch_all(&self.pool)
            .await
            .context("failed to load records")?;

        rows.into_iter().map(TryInto::try_into).collect()
    }

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

    async fn enqueue_sync_event(&self, profile_id: &str, record: &Record, operation: &str) -> Result<()> {
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
            direction: RecordDirection::try_from(row.direction.as_str()).map_err(anyhow::Error::msg)?,
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

impl TryFrom<CategoryStatsRow> for CategoryStatsItem {
    type Error = anyhow::Error;

    fn try_from(row: CategoryStatsRow) -> Result<Self> {
        Ok(Self {
            category: row.category,
            direction: RecordDirection::try_from(row.direction.as_str()).map_err(anyhow::Error::msg)?,
            total_amount: row.total_amount,
            record_count: row.record_count,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn migrations_create_sync_outbox() {
        let db_path = std::env::temp_dir().join(format!("billlens-apple-db-{}.sqlite", Uuid::new_v4()));
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
        let db_path = std::env::temp_dir().join(format!("billlens-apple-db-{}.sqlite", Uuid::new_v4()));
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
}
