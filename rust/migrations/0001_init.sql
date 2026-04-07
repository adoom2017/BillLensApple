CREATE TABLE IF NOT EXISTS records (
    id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    direction TEXT NOT NULL CHECK (direction IN ('income', 'expense')),
    amount REAL NOT NULL,
    currency TEXT NOT NULL DEFAULT 'CNY',
    category TEXT NOT NULL,
    merchant TEXT,
    transaction_at TIMESTAMP NOT NULL,
    note TEXT,
    device_id TEXT NOT NULL,
    sync_version INTEGER NOT NULL DEFAULT 1,
    deleted_at TIMESTAMP,
    needs_sync INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS records_profile_transaction_idx
    ON records (profile_id, transaction_at DESC);
CREATE INDEX IF NOT EXISTS records_profile_deleted_idx
    ON records (profile_id, deleted_at);

CREATE TABLE IF NOT EXISTS record_drafts (
    id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    content TEXT NOT NULL,
    auto_confirm INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'parsed' CHECK (status IN ('parsed', 'confirmed', 'discarded')),
    confirmed_record_id TEXT,
    direction TEXT CHECK (direction IN ('income', 'expense')),
    amount REAL,
    currency TEXT,
    category TEXT,
    merchant TEXT,
    transaction_at TIMESTAMP,
    note TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS record_drafts_profile_status_idx
    ON record_drafts (profile_id, status, updated_at DESC);

CREATE TABLE IF NOT EXISTS conversation_messages (
    id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
    content TEXT NOT NULL,
    draft_id TEXT,
    record_id TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS conversation_messages_profile_created_idx
    ON conversation_messages (profile_id, created_at);

CREATE TABLE IF NOT EXISTS sync_outbox (
    id TEXT PRIMARY KEY,
    record_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('create', 'update', 'delete')),
    payload TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    last_error TEXT
);

CREATE INDEX IF NOT EXISTS sync_outbox_profile_created_idx
    ON sync_outbox (profile_id, created_at);

CREATE TABLE IF NOT EXISTS sync_state (
    profile_id TEXT PRIMARY KEY,
    last_cursor TEXT,
    last_synced_at TIMESTAMP,
    last_error TEXT,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

