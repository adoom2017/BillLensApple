-- Replace the needs_sync flag with a synced_version watermark.
-- A row is dirty iff sync_version > synced_version. This removes the
-- possibility of the two fields disagreeing.

ALTER TABLE records ADD COLUMN synced_version INTEGER NOT NULL DEFAULT 0;
UPDATE records SET synced_version = CASE WHEN needs_sync = 1 THEN 0 ELSE sync_version END;
ALTER TABLE records DROP COLUMN needs_sync;

ALTER TABLE subscriptions ADD COLUMN synced_version INTEGER NOT NULL DEFAULT 0;
UPDATE subscriptions SET synced_version = CASE WHEN needs_sync = 1 THEN 0 ELSE sync_version END;
ALTER TABLE subscriptions DROP COLUMN needs_sync;

ALTER TABLE assets ADD COLUMN synced_version INTEGER NOT NULL DEFAULT 0;
UPDATE assets SET synced_version = CASE WHEN needs_sync = 1 THEN 0 ELSE sync_version END;
ALTER TABLE assets DROP COLUMN needs_sync;

ALTER TABLE asset_snapshots ADD COLUMN synced_version INTEGER NOT NULL DEFAULT 0;
UPDATE asset_snapshots SET synced_version = CASE WHEN needs_sync = 1 THEN 0 ELSE sync_version END;
ALTER TABLE asset_snapshots DROP COLUMN needs_sync;

ALTER TABLE app_settings ADD COLUMN synced_version INTEGER NOT NULL DEFAULT 0;
UPDATE app_settings SET synced_version = CASE WHEN needs_sync = 1 THEN 0 ELSE sync_version END;
ALTER TABLE app_settings DROP COLUMN needs_sync;
