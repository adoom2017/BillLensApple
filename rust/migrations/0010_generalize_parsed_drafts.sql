CREATE TABLE parsed_drafts (
    id TEXT PRIMARY KEY,
    batch_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('record', 'asset', 'subscription')),
    parser_source TEXT NOT NULL CHECK (parser_source IN ('local', 'cloud', 'cloud_after_local_failure')),
    original_content TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    fallback_reason TEXT,
    status TEXT NOT NULL DEFAULT 'parsed' CHECK (status IN ('parsed', 'confirmed', 'discarded')),
    confirmation_json TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO parsed_drafts (
    id,
    batch_id,
    profile_id,
    kind,
    parser_source,
    original_content,
    payload_json,
    status,
    confirmation_json,
    created_at,
    updated_at
)
SELECT
    id,
    id,
    profile_id,
    'record',
    'cloud',
    content,
    json_object(
        'direction', direction,
        'amount', amount,
        'currency', currency,
        'category', category,
        'merchant', merchant,
        'transaction_at', transaction_at,
        'note', note,
        'subscription_cycle', NULL,
        'asset_info', NULL
    ),
    status,
    CASE
        WHEN confirmed_record_id IS NULL THEN NULL
        ELSE json_object(
            'record_id', confirmed_record_id,
            'asset_id', NULL,
            'asset_snapshot_id', NULL,
            'subscription_id', NULL
        )
    END,
    created_at,
    updated_at
FROM record_drafts;

DROP TABLE record_drafts;

CREATE INDEX parsed_drafts_profile_status_idx
    ON parsed_drafts (profile_id, status, updated_at DESC);

CREATE INDEX parsed_drafts_batch_idx
    ON parsed_drafts (batch_id, created_at ASC);
