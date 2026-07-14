use std::{env, fmt};

use anyhow::{Context, Result, anyhow};
use billlens_apple_db::{
    ASSET_CATEGORIES, EXPENSE_CATEGORIES, INCOME_CATEGORIES, ParsedRecordPayload,
    is_valid_asset_category, is_valid_record_category, is_valid_record_category_for_direction,
};
use chrono::{Local, NaiveDate, Utc};
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::logger;

const RECORD_PROMPT_TEMPLATE: &str = r#"你是一个消费记录结构化助手。请将用户输入解析为 JSON。
今天的日期是：{today}
当前的时间是：{current_time}
必须严格返回 JSON，不要输出解释文字，不要输出 markdown。
如果输入包含多条交易记录（如账单列表、银行流水、多笔消费），请返回 JSON 数组，每条记录一个对象。如果只有一条记录，也返回包含一个元素的数组。
category 只能从以下固定分类中选择：
- 支出：{expense_categories}
- 收入：{income_categories}
如果无法判断分类，使用”其他”。
涉及会员、订阅、续费、月费、年费等周期性付费服务（如 ChatGPT、Netflix、iCloud、Spotify、视频会员等），应分类为”订阅”。
如果文本明确出现”退款””退回””退费””退款成功”等语义，应判断为收入，分类优先使用”其他”。
amount 必须始终返回正数，不要返回负数；收支方向只放在 direction 字段里表达。
只有当原始输入中明确出现时间线索时，才填写 transaction_at；如果原始输入没有体现任何时间信息，transaction_at 必须直接使用当前完整时间，精确到秒，不要只返回日期，不要返回当天 0 点，不要猜测、不要编造。
如果时间缺少时区，不要臆造 Z 或 UTC；优先返回原始本地时间字符串。
note 只保留与交易本身直接相关的简短备注；忽略积分、贴纸、奖励、营销文案、活动提示；如果没有合适备注，返回 null。
如果用户描述的是订阅/会员/周期性付费服务，额外返回 "subscription_cycle" 字段：
- "monthly" 表示每月付费
- "yearly" 表示每年付费
如果不是订阅类消费，subscription_cycle 返回 null。
判断依据：出现"订阅""会员""月费""年费""续费""每月""每年""包月""包年""月付""年付"等关键词时应识别为订阅。
如果用户描述的是资产余额/账户存款/投资持仓（如"招商银行存款还有 54000 元""支付宝余额 3000 块""股票账户 12 万""持有加密货币市值 5 万"等），额外返回 "asset_info" 字段：
{
  "name": 机构或品牌名（字符串，只保留核心机构/品牌名，去掉"账号""账户""股票""存款""基金""证券"等描述性后缀，如"东方财富股票账号"→"东方财富"，"招商银行存款账户"→"招商银行"）,
  "category": "{asset_categories_pipe}" 之一,
  "amount": 数字（正数）,
  "currency": ISO 4217 代码,
  "recorded_on": "YYYY-MM-DD" | null,
  "note": string | null
}
判断依据：出现"资产""余额""存款""还有 XX 元""账户里 XX""持仓""市值"等关键词，且主体是账户/机构而非消费动作。
资产记录时，direction/amount/category/merchant/transaction_at/subscription_cycle 一律返回 null，让 asset_info 独立表达。
如果不是资产描述，asset_info 返回 null。
JSON 格式如下：
[
  {
    "direction": "income" | "expense" | null,
    "amount": number | null,
    "currency": "ISO 4217 code, e.g. CNY/USD/EUR/HKD/JPY/GBP" | null,
    "category": string | null,
    "merchant": string | null,
    "transaction_at": "RFC3339 datetime" | null,
    "note": string | null,
    "subscription_cycle": "monthly" | "yearly" | null,
    "asset_info": { "name": string, "category": string, "amount": number, "currency": string, "recorded_on": string | null, "note": string | null } | null
  }
]
如果原文明确出现币种，请返回对应 ISO 4217 代码：
- 人民币 / 元 / 块 / RMB / ￥ / ¥ -> CNY
- 美元 / 美金 / $ / USD -> USD
- 港币 / 港元 / HK$ / HKD -> HKD
- 欧元 / € / EUR -> EUR
- 日元 / JPY -> JPY"#;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmConfig {
    pub base_url: String,
    pub api_key: String,
    pub model: String,
    pub provider: String,
}

impl LlmConfig {
    pub fn from_env_optional() -> Result<Option<Self>> {
        let read_optional = |name: &str| -> Result<Option<String>> {
            match env::var(name) {
                Ok(value) => Ok(Some(value)),
                Err(env::VarError::NotPresent) => Ok(None),
                Err(env::VarError::NotUnicode(_)) => {
                    Err(anyhow!("{name} contains invalid Unicode"))
                }
            }
        };
        let base_url = read_optional("LLM_BASE_URL")?;
        let api_key = read_optional("LLM_API_KEY")?;
        let model = read_optional("LLM_MODEL")?;
        let provider = read_optional("LLM_PROVIDER")?;
        if base_url.is_none() && api_key.is_none() && model.is_none() && provider.is_none() {
            return Ok(None);
        }
        let config = Self {
            base_url: base_url.ok_or_else(|| anyhow!("LLM_BASE_URL is required"))?,
            api_key: api_key.unwrap_or_default(),
            model: model.ok_or_else(|| anyhow!("LLM_MODEL is required"))?,
            provider: provider.ok_or_else(|| anyhow!("LLM_PROVIDER is required"))?,
        };
        config.validate()?;
        Ok(Some(config))
    }

    pub fn validate(&self) -> Result<()> {
        let base_url = self.base_url.trim();
        if base_url.is_empty() {
            return Err(anyhow!("LLM base_url is required"));
        }
        let parsed = reqwest::Url::parse(base_url).context("LLM base_url is invalid")?;
        if !matches!(parsed.scheme(), "http" | "https") {
            return Err(anyhow!("LLM base_url must use http or https"));
        }
        if self.model.trim().is_empty() {
            return Err(anyhow!("LLM model is required"));
        }
        if self.provider.trim().is_empty() {
            return Err(anyhow!("LLM provider is required"));
        }
        LlmProvider::parse(&self.provider)?;
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmModelItem {
    pub id: String,
    pub display_name: Option<String>,
    pub owned_by: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LlmProvider {
    OpenAi,
    Anthropic,
}

impl LlmProvider {
    pub fn parse(value: &str) -> Result<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "openai" | "llamacpp" | "deepseek" | "moonshot" | "zhipu" | "qwen" | "groq" | "xai"
            | "siliconflow" | "volcengine_ark" | "openai_compatible" => Ok(Self::OpenAi),
            "anthropic" => Ok(Self::Anthropic),
            _ => Err(anyhow!("unsupported llm provider: {value}")),
        }
    }
}

impl fmt::Display for LlmProvider {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let value = match self {
            Self::OpenAi => "openai",
            Self::Anthropic => "anthropic",
        };
        f.write_str(value)
    }
}

#[derive(Clone)]
pub struct CloudLlmClient {
    http: reqwest::Client,
    base_url: String,
    api_key: String,
    model: String,
    provider: LlmProvider,
    provider_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ModelListStrategy {
    OpenAiModels,
    AnthropicModels,
    XaiLanguageModels,
    SiliconFlowChatModels,
}

impl CloudLlmClient {
    pub fn from_config(config: LlmConfig) -> Result<Self> {
        config.validate()?;
        let provider = LlmProvider::parse(&config.provider).context("invalid LLM_PROVIDER")?;
        let provider_id = normalize_provider_id(&config.provider);
        Ok(Self::new(
            config.base_url,
            config.api_key,
            config.model,
            provider,
            provider_id,
        ))
    }

    pub fn new(
        base_url: String,
        api_key: String,
        model: String,
        provider: LlmProvider,
        provider_id: String,
    ) -> Self {
        Self {
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(60))
                .build()
                .expect("failed to build http client"),
            base_url,
            api_key,
            model,
            provider,
            provider_id,
        }
    }

    pub async fn parse_record_ocr_text_multi(
        &self,
        text: String,
    ) -> Result<Vec<ParsedRecordPayload>> {
        self.parse_records_multi(text).await
    }

    pub async fn parse_record_text_multi(&self, text: String) -> Result<Vec<ParsedRecordPayload>> {
        self.parse_records_multi(text).await
    }

    pub async fn list_models(&self) -> Result<Vec<LlmModelItem>> {
        let strategy = self.model_list_strategy();
        let path = match strategy {
            ModelListStrategy::OpenAiModels => "/models",
            ModelListStrategy::AnthropicModels => "/models",
            ModelListStrategy::XaiLanguageModels => "/language-models",
            ModelListStrategy::SiliconFlowChatModels => "/models?type=text&sub_type=chat",
        };
        let url = self.endpoint_url(path);
        logger::info(
            "llm.models.request",
            format!(
                "provider={} strategy={strategy:?} url={url}",
                self.provider_id
            ),
        );
        let request = self.authorize_request(self.http.get(url));
        let payload: Value = request
            .send()
            .await
            .context("failed to list llm models")?
            .error_for_status()
            .context("llm models endpoint returned error status")?
            .json()
            .await
            .context("failed to decode llm models response")?;
        let items = parse_llm_model_items(&payload)?;
        logger::info(
            "llm.models.response",
            format!("provider={} count={}", self.provider_id, items.len()),
        );
        Ok(items)
    }

    async fn parse_records_multi(&self, text: String) -> Result<Vec<ParsedRecordPayload>> {
        let prompt = build_record_prompt();
        logger::info(
            "llm.request",
            format!("provider={} model={} mode=multi", self.provider, self.model,),
        );
        let response = self.send_prompted_request(prompt, text.clone()).await?;
        let raw_response_text = response
            .text()
            .await
            .context("failed to read llm response body")?;
        let raw_response: Value =
            serde_json::from_str(&raw_response_text).context("failed to decode llm response")?;
        let content = extract_message_content(&self.provider, &raw_response)?;
        let payloads = parse_record_payloads_strict(&content)?;
        logger::info(
            "llm.response.parsed_multi",
            format!("count={}", payloads.len()),
        );
        Ok(payloads)
    }

    async fn send_prompted_request(
        &self,
        system_prompt: String,
        text: String,
    ) -> Result<reqwest::Response> {
        let (path, body) = match self.provider {
            LlmProvider::OpenAi => (
                "/chat/completions",
                build_openai_request_body(&self.model, system_prompt, text),
            ),
            LlmProvider::Anthropic => (
                "/messages",
                build_anthropic_request_body(&self.model, system_prompt, text),
            ),
        };

        let url = self.endpoint_url(path);
        logger::info("llm.http", format!("url={url}"));
        let request = self.http.post(url).header(CONTENT_TYPE, "application/json");
        let request = self.authorize_request(request);

        request
            .json(&body)
            .send()
            .await
            .context("failed to call llm provider")?
            .error_for_status()
            .context("llm provider returned error status")
    }

    fn endpoint_url(&self, path: &str) -> String {
        format!(
            "{}/{}",
            self.base_url.trim_end_matches('/'),
            path.trim_start_matches('/')
        )
    }

    fn authorize_request(&self, request: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        match self.provider {
            LlmProvider::OpenAi => {
                if self.api_key.trim().is_empty() {
                    request
                } else {
                    request.header(AUTHORIZATION, format!("Bearer {}", self.api_key))
                }
            }
            LlmProvider::Anthropic => request
                .header("x-api-key", &self.api_key)
                .header("anthropic-version", "2023-06-01"),
        }
    }

    fn model_list_strategy(&self) -> ModelListStrategy {
        match self.provider_id.as_str() {
            "anthropic" => ModelListStrategy::AnthropicModels,
            "xai" => ModelListStrategy::XaiLanguageModels,
            "siliconflow" => ModelListStrategy::SiliconFlowChatModels,
            _ => ModelListStrategy::OpenAiModels,
        }
    }
}

fn normalize_provider_id(value: &str) -> String {
    value.trim().to_ascii_lowercase()
}

fn parse_llm_model_items(payload: &Value) -> Result<Vec<LlmModelItem>> {
    let items = payload
        .get("data")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("llm models response missing data array"))?;
    items.iter().map(parse_llm_model_item).collect()
}

fn parse_llm_model_item(value: &Value) -> Result<LlmModelItem> {
    let object = value
        .as_object()
        .ok_or_else(|| anyhow!("llm model entry is not an object"))?;
    let id = object
        .get("id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("llm model entry missing id"))?
        .to_string();
    let display_name = object
        .get("display_name")
        .or_else(|| object.get("name"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string);
    let owned_by = object
        .get("owned_by")
        .or_else(|| object.get("ownedBy"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string);
    Ok(LlmModelItem {
        id,
        display_name,
        owned_by,
    })
}

pub(crate) fn build_record_prompt() -> String {
    RECORD_PROMPT_TEMPLATE
        .replace("{today}", &Utc::now().format("%Y-%m-%d").to_string())
        .replace(
            "{current_time}",
            &Local::now().format("%Y-%m-%d %H:%M:%S").to_string(),
        )
        .replace("{expense_categories}", &EXPENSE_CATEGORIES.join("、"))
        .replace("{income_categories}", &INCOME_CATEGORIES.join("、"))
        .replace("{asset_categories_pipe}", &ASSET_CATEGORIES.join("|"))
}

fn build_openai_request_body(model: &str, system_prompt: String, text: String) -> Value {
    json!({
        "model": model,
        "stream": false,
        "max_tokens": 2048,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": text}
        ]
    })
}

fn build_anthropic_request_body(model: &str, system_prompt: String, text: String) -> Value {
    json!({
        "model": model,
        "stream": false,
        "max_tokens": 2048,
        "system": system_prompt,
        "messages": [
            {
                "role": "user",
                "content": [
                    { "type": "text", "text": text }
                ]
            }
        ]
    })
}

fn extract_message_content(provider: &LlmProvider, raw_response: &Value) -> Result<String> {
    match provider {
        LlmProvider::OpenAi => extract_openai_message_content(raw_response),
        LlmProvider::Anthropic => extract_anthropic_message_content(raw_response),
    }
}

fn extract_openai_message_content(raw_response: &Value) -> Result<String> {
    let choices = raw_response
        .get("choices")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("llm response missing choices"))?;
    let first = choices
        .first()
        .ok_or_else(|| anyhow!("llm response did not contain any choices"))?;
    let content = first
        .get("message")
        .and_then(|message| message.get("content"))
        .ok_or_else(|| anyhow!("llm response missing message content"))?;

    match content {
        Value::String(text) => Ok(text.clone()),
        Value::Array(parts) => {
            let text = parts
                .iter()
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n");
            if text.is_empty() {
                Err(anyhow!(
                    "llm response content array did not contain text parts"
                ))
            } else {
                Ok(text)
            }
        }
        _ => Err(anyhow!("unsupported llm response content shape")),
    }
}

fn extract_anthropic_message_content(raw_response: &Value) -> Result<String> {
    let content = raw_response
        .get("content")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("anthropic response missing content"))?;
    let text = content
        .iter()
        .filter_map(|part| {
            if part.get("type").and_then(Value::as_str) == Some("text") {
                part.get("text").and_then(Value::as_str)
            } else {
                None
            }
        })
        .collect::<Vec<_>>()
        .join("\n");

    if text.is_empty() {
        Err(anyhow!("anthropic response did not contain text blocks"))
    } else {
        Ok(text)
    }
}

pub(crate) fn parse_record_payloads_strict(content: &str) -> Result<Vec<ParsedRecordPayload>> {
    let payloads: Vec<ParsedRecordPayload> = serde_json::from_str(content.trim())
        .context("LLM response must be a JSON array matching the record contract")?;
    if payloads.is_empty() {
        return Err(anyhow!("LLM response contains no parsed records"));
    }
    for payload in &payloads {
        validate_record_payload_contract(payload)?;
    }
    Ok(payloads)
}

fn validate_record_payload_contract(payload: &ParsedRecordPayload) -> Result<()> {
    if payload.asset_info.is_some() && payload.subscription_cycle.is_some() {
        return Err(anyhow!(
            "LLM payload cannot be both an asset and a subscription"
        ));
    }
    if let Some(amount) = payload.amount {
        if !amount.is_finite() || amount <= 0.0 {
            return Err(anyhow!(
                "LLM payload amount must be a finite positive number"
            ));
        }
    }
    if let Some(currency) = payload.currency.as_deref() {
        let normalized = normalize_currency_code(currency)
            .ok_or_else(|| anyhow!("LLM payload contains an invalid currency"))?;
        if normalized != currency {
            return Err(anyhow!("LLM payload currency must be a canonical ISO code"));
        }
    }
    if let Some(category) = payload.category.as_deref() {
        if !is_valid_record_category(category) {
            return Err(anyhow!("LLM payload contains an invalid record category"));
        }
        if !is_valid_record_category_for_direction(payload.direction.as_ref(), category) {
            return Err(anyhow!(
                "LLM payload category is invalid for its record direction"
            ));
        }
    }
    if let Some(asset) = payload.asset_info.as_ref() {
        if asset.name.trim().is_empty() {
            return Err(anyhow!("LLM asset payload name is required"));
        }
        if !asset.amount.is_finite() || asset.amount <= 0.0 {
            return Err(anyhow!(
                "LLM asset payload amount must be a finite positive number"
            ));
        }
        if let Some(category) = asset.category.as_deref() {
            if !is_valid_asset_category(category) {
                return Err(anyhow!("LLM asset payload category is invalid"));
            }
        }
        if let Some(currency) = asset.currency.as_deref() {
            let normalized = normalize_currency_code(currency)
                .ok_or_else(|| anyhow!("LLM asset payload currency is invalid"))?;
            if normalized != currency {
                return Err(anyhow!(
                    "LLM asset payload currency must be a canonical ISO code"
                ));
            }
        }
        if let Some(recorded_on) = asset.recorded_on.as_deref() {
            NaiveDate::parse_from_str(recorded_on, "%Y-%m-%d")
                .context("LLM asset payload recorded_on must be YYYY-MM-DD")?;
        }
    }
    Ok(())
}

/// Aliases accepted for explicit user input and legacy stored values.
/// Model output still has to equal the canonical code after normalization.
const CURRENCY_KEYWORDS: &[(&[&str], &str)] = &[
    (&["港币", "港元", "HKD", "HK$"], "HKD"),
    (&["美元", "美金", "USD", "US$"], "USD"),
    (&["欧元", "EUR", "€"], "EUR"),
    (&["日元", "JPY"], "JPY"),
    (&["英镑", "GBP", "£"], "GBP"),
    (&["新加坡元", "新币", "SGD", "S$"], "SGD"),
    (&["澳元", "澳币", "AUD", "A$"], "AUD"),
    (&["加元", "CAD", "C$"], "CAD"),
    (&["韩元", "韩币", "KRW", "₩"], "KRW"),
    (&["新台币", "台币", "TWD", "NT$"], "TWD"),
    (&["澳门元", "葡币", "MOP", "MOP$"], "MOP"),
    (&["泰铢", "THB", "฿"], "THB"),
    (&["马币", "林吉特", "MYR", "RM"], "MYR"),
    (&["人民币", "RMB", "CNY", "CNH", "￥", "¥"], "CNY"),
];

pub(crate) fn normalize_currency_code(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }

    let compact: String = trimmed
        .chars()
        .filter(|ch| !ch.is_whitespace() && *ch != '-' && *ch != '_')
        .collect();
    let upper = compact.to_ascii_uppercase();

    for (keywords, code) in CURRENCY_KEYWORDS {
        if keywords
            .iter()
            .any(|keyword| trimmed.contains(keyword) || upper.contains(keyword))
        {
            return Some(code.to_string());
        }
    }

    if upper == "$" {
        return Some("USD".to_string());
    }

    if trimmed.contains('元') || trimmed.contains('块') {
        return Some("CNY".to_string());
    }

    if upper.len() == 3 && upper.chars().all(|ch| ch.is_ascii_alphabetic()) {
        return Some(upper);
    }

    None
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{
        LlmProvider, normalize_currency_code, parse_llm_model_items, parse_record_payloads_strict,
    };

    #[test]
    fn provider_parse_supports_original_values() {
        assert!(matches!(
            LlmProvider::parse("openai").unwrap(),
            LlmProvider::OpenAi
        ));
        assert!(matches!(
            LlmProvider::parse("llamacpp").unwrap(),
            LlmProvider::OpenAi
        ));
        assert!(matches!(
            LlmProvider::parse("anthropic").unwrap(),
            LlmProvider::Anthropic
        ));
        assert!(matches!(
            LlmProvider::parse("groq").unwrap(),
            LlmProvider::OpenAi
        ));
        assert!(matches!(
            LlmProvider::parse("xai").unwrap(),
            LlmProvider::OpenAi
        ));
        assert!(matches!(
            LlmProvider::parse("siliconflow").unwrap(),
            LlmProvider::OpenAi
        ));
        assert!(matches!(
            LlmProvider::parse("volcengine_ark").unwrap(),
            LlmProvider::OpenAi
        ));
    }

    #[test]
    fn parse_llm_model_items_supports_openai_shape() {
        let items = parse_llm_model_items(&json!({
            "data": [
                { "id": "gpt-4o", "owned_by": "openai" },
                { "id": "gpt-4.1-mini", "owned_by": "openai" }
            ]
        }))
        .unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].id, "gpt-4o");
        assert_eq!(items[0].owned_by.as_deref(), Some("openai"));
    }

    #[test]
    fn parse_llm_model_items_supports_anthropic_shape() {
        let items = parse_llm_model_items(&json!({
            "data": [
                { "id": "claude-sonnet-4-6", "display_name": "Claude Sonnet 4.6" }
            ]
        }))
        .unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "claude-sonnet-4-6");
        assert_eq!(items[0].display_name.as_deref(), Some("Claude Sonnet 4.6"));
    }

    #[test]
    fn strict_parser_accepts_exact_json_array_contract() {
        let payloads = parse_record_payloads_strict(
            r#"[{"direction":"expense","amount":35,"currency":"CNY","category":"餐饮","merchant":null,"transaction_at":"2026-07-14T12:00:00Z","note":null,"subscription_cycle":null,"asset_info":null}]"#,
        )
        .unwrap();
        assert_eq!(payloads.len(), 1);
        assert_eq!(payloads[0].amount, Some(35.0));
    }

    #[test]
    fn strict_parser_rejects_markdown_and_nested_string_json() {
        assert!(parse_record_payloads_strict("```json\n[]\n```").is_err());
        assert!(parse_record_payloads_strict(r#""[{\"direction\":null}]""#).is_err());
    }

    #[test]
    fn strict_parser_rejects_currency_aliases() {
        assert!(
            parse_record_payloads_strict(
                r#"[{"direction":"expense","amount":12,"currency":"美元","category":"餐饮","merchant":null,"transaction_at":null,"note":null,"subscription_cycle":null,"asset_info":null}]"#,
            )
            .is_err()
        );
    }

    #[test]
    fn normalize_currency_code_accepts_iso_and_symbol_variants() {
        assert_eq!(normalize_currency_code("usd").as_deref(), Some("USD"));
        assert_eq!(normalize_currency_code("港币").as_deref(), Some("HKD"));
        assert_eq!(normalize_currency_code("€").as_deref(), Some("EUR"));
    }
}
