CREATE TABLE IF NOT EXISTS fx_rates (
    base_currency TEXT NOT NULL,
    quote_currency TEXT NOT NULL,
    rate REAL NOT NULL,
    rate_date TEXT NOT NULL,
    fetched_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (base_currency, quote_currency, rate_date)
);

CREATE INDEX IF NOT EXISTS fx_rates_pair_fetched_idx
    ON fx_rates (base_currency, quote_currency, fetched_at DESC, rate_date DESC);
