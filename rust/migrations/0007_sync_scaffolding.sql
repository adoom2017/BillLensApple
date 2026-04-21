ALTER TABLE subscriptions ADD COLUMN sync_version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE subscriptions ADD COLUMN needs_sync INTEGER NOT NULL DEFAULT 1;
ALTER TABLE subscriptions ADD COLUMN device_id TEXT NOT NULL DEFAULT '';

ALTER TABLE assets ADD COLUMN sync_version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE assets ADD COLUMN needs_sync INTEGER NOT NULL DEFAULT 1;
ALTER TABLE assets ADD COLUMN device_id TEXT NOT NULL DEFAULT '';

ALTER TABLE asset_snapshots ADD COLUMN sync_version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE asset_snapshots ADD COLUMN needs_sync INTEGER NOT NULL DEFAULT 1;
ALTER TABLE asset_snapshots ADD COLUMN deleted_at TEXT;
ALTER TABLE asset_snapshots ADD COLUMN device_id TEXT NOT NULL DEFAULT '';

-- Partial unique index so soft-deleted snapshots don't block re-inserts on the same day.
DROP INDEX IF EXISTS idx_asset_snapshots_asset_day;
CREATE UNIQUE INDEX IF NOT EXISTS idx_asset_snapshots_asset_day
    ON asset_snapshots(asset_id, recorded_on) WHERE deleted_at IS NULL;

ALTER TABLE app_settings ADD COLUMN sync_version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE app_settings ADD COLUMN needs_sync INTEGER NOT NULL DEFAULT 1;
ALTER TABLE app_settings ADD COLUMN deleted_at TEXT;
ALTER TABLE app_settings ADD COLUMN device_id TEXT NOT NULL DEFAULT '';

ALTER TABLE sync_outbox ADD COLUMN entity_type TEXT NOT NULL DEFAULT 'record';

CREATE TABLE IF NOT EXISTS sync_cursor (
    profile_id TEXT NOT NULL,
    zone       TEXT NOT NULL,
    token      TEXT,
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (profile_id, zone)
);
