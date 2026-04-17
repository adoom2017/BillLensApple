-- Asset management (balance snapshots over time)
CREATE TABLE IF NOT EXISTS assets (
    id              TEXT PRIMARY KEY,
    profile_id      TEXT NOT NULL,
    name            TEXT NOT NULL,
    category        TEXT NOT NULL,
    currency        TEXT NOT NULL DEFAULT 'CNY',
    note            TEXT,
    deleted_at      TEXT,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_assets_profile_name_live
    ON assets(profile_id, name) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS asset_snapshots (
    id              TEXT PRIMARY KEY,
    asset_id        TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    profile_id      TEXT NOT NULL,
    amount          REAL NOT NULL,
    recorded_on     TEXT NOT NULL,
    note            TEXT,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_asset_snapshots_asset_day
    ON asset_snapshots(asset_id, recorded_on);

CREATE INDEX IF NOT EXISTS idx_asset_snapshots_asset_recorded
    ON asset_snapshots(asset_id, recorded_on DESC);
