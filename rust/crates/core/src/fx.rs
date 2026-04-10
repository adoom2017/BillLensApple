use anyhow::{Context, Result, anyhow};
use billlens_apple_db::BillRepository;
use chrono::{DateTime, NaiveDate, Utc};
use reqwest::StatusCode;
use serde::Deserialize;

const FX_API_BASE_URL: &str = "https://api.frankfurter.dev/v2";

#[derive(Clone)]
pub struct FxClient {
    http: reqwest::Client,
}

impl FxClient {
    pub fn new() -> Self {
        Self {
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(10))
                .build()
                .expect("failed to build fx http client"),
        }
    }

    pub async fn fetch_latest_rate(
        &self,
        base_currency: &str,
        quote_currency: &str,
    ) -> Result<FxQuote> {
        let response = self
            .http
            .get(format!("{FX_API_BASE_URL}/rates"))
            .query(&[("base", base_currency), ("quotes", quote_currency)])
            .send()
            .await
            .context("failed to fetch latest fx rate")?;

        let status = response.status();
        if status != StatusCode::OK {
            let body = response
                .text()
                .await
                .unwrap_or_else(|_| "<unreadable body>".to_string());
            return Err(anyhow!("fx provider returned {status}: {body}"));
        }

        let rows: Vec<FrankfurterRateRow> = response
            .json()
            .await
            .context("failed to decode fx provider response")?;
        let row = rows
            .into_iter()
            .next()
            .ok_or_else(|| anyhow!("fx provider returned empty rate set"))?;

        if row.base != base_currency || row.quote != quote_currency {
            return Err(anyhow!("fx provider returned mismatched currency pair"));
        }
        if row.rate <= 0.0 {
            return Err(anyhow!("fx provider returned non-positive rate"));
        }

        Ok(FxQuote {
            base_currency: row.base,
            quote_currency: row.quote,
            rate: row.rate,
            rate_date: row.date,
            fetched_at: Utc::now(),
        })
    }
}

#[derive(Debug, Clone)]
pub struct FxQuote {
    pub base_currency: String,
    pub quote_currency: String,
    pub rate: f64,
    pub rate_date: NaiveDate,
    pub fetched_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FxResolution {
    pub used_cached_rate: bool,
}

pub async fn resolve_fx_rate(
    repo: &BillRepository,
    client: &FxClient,
    base_currency: &str,
    quote_currency: &str,
) -> Result<(f64, FxResolution)> {
    if base_currency == quote_currency {
        return Ok((
            1.0,
            FxResolution {
                used_cached_rate: false,
            },
        ));
    }

    match client
        .fetch_latest_rate(base_currency, quote_currency)
        .await
    {
        Ok(quote) => {
            repo.upsert_fx_rate(
                &quote.base_currency,
                &quote.quote_currency,
                quote.rate,
                quote.rate_date,
                quote.fetched_at,
            )
            .await?;
            Ok(select_rate_resolution(Ok(quote), None)?)
        }
        Err(fetch_error) => {
            let cached = repo.latest_fx_rate(base_currency, quote_currency).await?;
            Ok(select_rate_resolution(Err(fetch_error), cached)?)
        }
    }
}

fn select_rate_resolution(
    fetch_result: Result<FxQuote>,
    cached: Option<billlens_apple_db::FxRateCache>,
) -> Result<(f64, FxResolution)> {
    match fetch_result {
        Ok(quote) => Ok((
            quote.rate,
            FxResolution {
                used_cached_rate: false,
            },
        )),
        Err(fetch_error) => {
            let cached = cached.ok_or(fetch_error)?;
            Ok((
                cached.rate,
                FxResolution {
                    used_cached_rate: true,
                },
            ))
        }
    }
}

#[derive(Debug, Deserialize)]
struct FrankfurterRateRow {
    date: NaiveDate,
    base: String,
    quote: String,
    rate: f64,
}

#[cfg(test)]
mod tests {
    use billlens_apple_db::FxRateCache;

    use super::*;

    fn sample_quote() -> FxQuote {
        FxQuote {
            base_currency: "USD".to_string(),
            quote_currency: "CNY".to_string(),
            rate: 6.83,
            rate_date: NaiveDate::from_ymd_opt(2026, 4, 10).unwrap(),
            fetched_at: Utc::now(),
        }
    }

    fn sample_cache() -> FxRateCache {
        FxRateCache {
            base_currency: "USD".to_string(),
            quote_currency: "CNY".to_string(),
            rate: 6.75,
            rate_date: NaiveDate::from_ymd_opt(2026, 4, 9).unwrap(),
            fetched_at: Utc::now(),
        }
    }

    #[test]
    fn sample_quote_is_positive() {
        assert!(sample_quote().rate > 0.0);
    }

    #[test]
    fn sample_cache_is_positive() {
        assert!(sample_cache().rate > 0.0);
    }

    #[test]
    fn select_rate_resolution_uses_cache_when_fetch_fails() {
        let (rate, resolution) =
            select_rate_resolution(Err(anyhow!("network failed")), Some(sample_cache())).unwrap();
        assert_eq!(rate, 6.75);
        assert!(resolution.used_cached_rate);
    }

    #[test]
    fn select_rate_resolution_fails_without_cache() {
        let error = select_rate_resolution(Err(anyhow!("network failed")), None).unwrap_err();
        assert_eq!(error.to_string(), "network failed");
    }
}
