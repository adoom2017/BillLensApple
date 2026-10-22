-- 允许规则解析（不经过模型）生成的草稿：parser_source 增加 'rule'。
-- SQLite 无法修改 CHECK 约束，按原结构重建表。
CREATE TABLE parsed_drafts_new (
    id TEXT PRIMARY KEY,
    batch_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('record', 'asset', 'subscription')),
    parser_source TEXT NOT NULL CHECK (parser_source IN ('rule', 'local', 'cloud', 'cloud_after_local_failure')),
    original_content TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    fallback_reason TEXT,
    status TEXT NOT NULL DEFAULT 'parsed' CHECK (status IN ('parsed', 'confirmed', 'discarded')),
    confirmation_json TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO parsed_drafts_new (
    id, batch_id, profile_id, kind, parser_source, original_content, payload_json,
    fallback_reason, status, confirmation_json, created_at, updated_at
)
SELECT
    id, batch_id, profile_id, kind, parser_source, original_content, payload_json,
    fallback_reason, status, confirmation_json, created_at, updated_at
FROM parsed_drafts;

DROP TABLE parsed_drafts;
ALTER TABLE parsed_drafts_new RENAME TO parsed_drafts;

CREATE INDEX parsed_drafts_profile_status_idx
    ON parsed_drafts (profile_id, status, updated_at DESC);

CREATE INDEX parsed_drafts_batch_idx
    ON parsed_drafts (batch_id, created_at ASC);
