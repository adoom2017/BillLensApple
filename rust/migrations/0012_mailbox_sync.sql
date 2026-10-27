-- 邮箱账单同步：仅本机状态，不参与 CloudKit。令牌存钥匙串，不在此处。
CREATE TABLE IF NOT EXISTS mail_sync_state (
    profile_id TEXT PRIMARY KEY,
    account_address TEXT NOT NULL,
    -- 已处理到的最新邮件接收时间（UTC）；NULL 表示从首次回溯窗口开始。
    cursor TIMESTAMP,
    last_synced_at TIMESTAMP,
    last_error TEXT,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 每封已处理的账单邮件。raw_mime 只为待确认账单保留，处理完即清空。
CREATE TABLE IF NOT EXISTS mail_messages (
    id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    received_at TIMESTAMP NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('imported', 'needs_review', 'skipped')),
    raw_mime BLOB,
    period_label TEXT,
    imported_count INTEGER NOT NULL DEFAULT 0,
    pending_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (profile_id, id)
);

CREATE INDEX IF NOT EXISTS mail_messages_review_idx
    ON mail_messages (profile_id, status, received_at);
