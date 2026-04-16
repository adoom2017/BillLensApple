-- Subscription (periodic billing) support
CREATE TABLE IF NOT EXISTS subscriptions (
    id              TEXT PRIMARY KEY,
    profile_id      TEXT NOT NULL,
    direction       TEXT NOT NULL CHECK (direction IN ('income', 'expense')),
    amount          REAL NOT NULL,
    currency        TEXT NOT NULL DEFAULT 'CNY',
    category        TEXT NOT NULL,
    merchant        TEXT,
    note            TEXT,
    cycle           TEXT NOT NULL CHECK (cycle IN ('monthly', 'yearly')),
    anchor_day      INTEGER NOT NULL,
    anchor_month    INTEGER,
    next_due_at     TEXT NOT NULL,
    last_charged_at TEXT,
    is_active       INTEGER NOT NULL DEFAULT 1,
    deleted_at      TEXT,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_profile_active
    ON subscriptions(profile_id, is_active) WHERE deleted_at IS NULL;
