-- sync_outbox was superseded by per-row sync_version/synced_version watermarks.
DROP INDEX IF EXISTS sync_outbox_profile_created_idx;
DROP TABLE IF EXISTS sync_outbox;
