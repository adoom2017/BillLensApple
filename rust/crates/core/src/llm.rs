use std::{env, fmt};

use anyhow::{Context, Result, anyhow};
use billlens_apple_db::{
    ASSET_CATEGORIES, EXPENSE_CATEGORIES, INCOME_CATEGORIES, ParsedAssetInfo, ParsedRecordPayload,
    RecordDirection, SubscriptionCycle, is_valid_asset_category, is_valid_record_category,
    is_valid_record_category_for_direction,
};
use chrono::{DateTime, NaiveDate, Utc};
use chrono_tz::Tz;
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::{EntrySource, logger, rule_parser};

const TEXT_INPUT_RULES: &str =
    r#"输入来自用户直接表述。按原文明确语义提取字段，不要补充原文没有表达的交易对象或用途。"#;

const OCR_INPUT_RULES: &str = r#"输入来自账单、收据、银行流水或支付凭证的 OCR 文本，页面样式和 OCR 行顺序都不固定。不要依据文字出现顺序、字号或视觉显著性选择字段，必须依据字段标签、上下文语义和交易角色选择证据：
- time_text 摘录凭证中明确标注的实际支付、交易、记账或入账时间原文；设备状态栏时间、截图时间、页面更新时间不是交易时间。凭证中没有交易时间时返回 null。
- merchant 优先使用实际收款方、商户、店铺或服务提供方；电商平台、支付平台、银行和支付渠道只有在其本身就是明确交易对手时才能作为 merchant，不能因为名称更醒目而覆盖更具体的交易对手。
- note 表示本次交易购买的商品或服务、交易用途或用户备注。存在商品或服务名称时，提取能区分交易的简短核心名称，去掉规格堆叠和营销修饰。
- 订单、支付、履约、物流或退款流程状态可以帮助判断交易，但不能直接作为 note。订单号、流水号、支付工具、银行卡尾号、积分奖励、广告活动和页面功能说明也不能作为 note。
- 如果没有明确的商品、服务、用途或用户备注，note 返回 null；不要用页面上最靠近金额的文字填充。"#;

const RECORD_PROMPT_TEMPLATE: &str = r#"你是记账助手，把用户输入解析成 JSON 数组，每笔交易一个对象；只有一笔也返回包含一个元素的数组。只输出 JSON，不要解释，不要 markdown。
{input_source_rules}
{pinned_fields}
字段规则：
- direction："expense" 支出，"income" 收入。退款、退回、退费属于收入。
- amount：正数；收支方向只放在 direction。
- currency：原文出现币种时返回 ISO 4217 代码（元/块/人民币/¥ → CNY，美元/美金/$ → USD，港币/港元 → HKD，欧元/€ → EUR，日元 → JPY，英镑/£ → GBP）；原文没有币种返回 null。
- category：只能从固定分类中选择。支出：{expense_categories}；收入：{income_categories}。平台或账单原有分类只是线索，必须映射到固定分类；无法判断用“其他”。服装、鞋靴、数码等实体商品用“购物”；会员、订阅、续费等周期付费用“订阅”；退款用“退款”。
- merchant：实际交易对手（商户、店铺、服务方）；没有返回 null。
- note：交易的商品、服务或用途的简短描述，不含编号、支付工具、营销文案；没有返回 null。
- time_text：原文中描述交易时间的片段，原样摘录，不要换算或补全（如“今天早上”“昨晚8点”“10月3日”“2026-10-22 08:15”）；原文没有时间返回 null。
- subscription_cycle：订阅、会员、续费等周期付费时返回 "monthly" 或 "yearly"，否则 null。
- asset_info：仅当描述账户余额、存款、持仓、市值等资产状态（不是消费动作）时返回，此时其余字段全部为 null：
  {"name": 核心机构或品牌名（去掉“账户”“存款”“股票”等后缀，如“招商银行存款账户”→“招商银行”）, "category": "{asset_categories_pipe}" 之一, "amount": 正数, "currency": ISO 代码或 null, "recorded_on": "YYYY-MM-DD" 或 null, "note": 字符串或 null}
示例：
输入：今天早上打车花了30块
输出：[{"direction":"expense","amount":30,"currency":"CNY","category":"交通","merchant":null,"time_text":"今天早上","note":"打车","subscription_cycle":null,"asset_info":null}]
输入：订阅了 Netflix 每月 15.99 美元
输出：[{"direction":"expense","amount":15.99,"currency":"USD","category":"订阅","merchant":"Netflix","time_text":null,"note":null,"subscription_cycle":"monthly","asset_info":null}]
输入：招商银行存款还有54000元
输出：[{"direction":null,"amount":null,"currency":null,"category":null,"merchant":null,"time_text":null,"note":null,"subscription_cycle":null,"asset_info":{"name":"招商银行","category":"存款","amount":54000,"currency":"CNY","recorded_on":null,"note":null}}]"#;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmConfig {
    pub base_url: String,
    pub api_key: String,
    pub model: String,
    pub provider: String,
    #[serde(default)]
    pub enable_thinking: Option<bool>,
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
            enable_thinking: None,
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
    enable_thinking: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ModelListStrategy {
    OpenAi,
    Anthropic,
    XaiLanguage,
    SiliconFlowChat,
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
            config.enable_thinking,
        ))
    }

    pub fn new(
        base_url: String,
        api_key: String,
        model: String,
        provider: LlmProvider,
        provider_id: String,
        enable_thinking: Option<bool>,
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
            enable_thinking,
        }
    }

    pub(crate) async fn parse_records(
        &self,
        text: String,
        source: &EntrySource,
        system_prompt: String,
        now: DateTime<Tz>,
    ) -> Result<Vec<ParsedRecordPayload>> {
        self.parse_records_multi(text, source, system_prompt, now)
            .await
    }

    pub async fn list_models(&self) -> Result<Vec<LlmModelItem>> {
        let strategy = self.model_list_strategy();
        let path = match strategy {
            ModelListStrategy::OpenAi => "/models",
            ModelListStrategy::Anthropic => "/models",
            ModelListStrategy::XaiLanguage => "/language-models",
            ModelListStrategy::SiliconFlowChat => "/models?type=text&sub_type=chat",
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

    async fn parse_records_multi(
        &self,
        text: String,
        source: &EntrySource,
        prompt: String,
        now: DateTime<Tz>,
    ) -> Result<Vec<ParsedRecordPayload>> {
        let thinking_mode = self
            .enable_thinking
            .map(|value| value.to_string())
            .unwrap_or_else(|| "provider_default".to_string());
        logger::info(
            "llm.request",
            format!(
                "provider={} model={} mode=multi source={} enable_thinking={thinking_mode}",
                self.provider,
                self.model,
                entry_source_name(source),
            ),
        );
        let response = self.send_prompted_request(prompt, text.clone()).await?;
        let raw_response_text = response
            .text()
            .await
            .context("failed to read llm response body")?;
        let raw_response: Value = serde_json::from_str(&raw_response_text).map_err(|error| {
            anyhow!(
                "failed to decode llm response envelope: {}; {}; parser_error={error}",
                summarize_text_output(&raw_response_text),
                summarize_json_error_location(&raw_response_text, &error)
            )
        })?;
        logger::info(
            "llm.cloud.response",
            format!(
                "provider={} model={} {}",
                self.provider_id,
                self.model,
                summarize_provider_response(&self.provider, &raw_response)
            ),
        );
        let content = extract_message_content(&self.provider, &raw_response)?;
        logger::info(
            "llm.cloud.output",
            format!(
                "provider={} model={} {}",
                self.provider_id,
                self.model,
                summarize_text_output(&content)
            ),
        );
        let payloads = parse_record_payloads_strict(&content, now)?;
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
                build_openai_request_body(&self.model, system_prompt, text, self.enable_thinking),
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
            "anthropic" => ModelListStrategy::Anthropic,
            "xai" => ModelListStrategy::XaiLanguage,
            "siliconflow" => ModelListStrategy::SiliconFlowChat,
            _ => ModelListStrategy::OpenAi,
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

/// `pinned_fields` 是规则解析已确定的字段说明，模型输出后仍由代码覆盖。
pub(crate) fn build_record_prompt(source: &EntrySource, pinned_fields: Option<&str>) -> String {
    RECORD_PROMPT_TEMPLATE
        .replace("{input_source_rules}", input_source_rules(source))
        .replace("{pinned_fields}", pinned_fields.unwrap_or(""))
        .replace("{expense_categories}", &EXPENSE_CATEGORIES.join("、"))
        .replace("{income_categories}", &INCOME_CATEGORIES.join("、"))
        .replace("{asset_categories_pipe}", &ASSET_CATEGORIES.join("|"))
}

fn input_source_rules(source: &EntrySource) -> &'static str {
    match source {
        EntrySource::Text => TEXT_INPUT_RULES,
        EntrySource::Ocr => OCR_INPUT_RULES,
    }
}

fn entry_source_name(source: &EntrySource) -> &'static str {
    match source {
        EntrySource::Text => "text",
        EntrySource::Ocr => "ocr",
    }
}

fn build_openai_request_body(
    model: &str,
    system_prompt: String,
    text: String,
    enable_thinking: Option<bool>,
) -> Value {
    let mut body = json!({
        "model": model,
        "stream": false,
        "max_tokens": 2048,
        "temperature": 0,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": text}
        ]
    });
    if let Some(enable_thinking) = enable_thinking {
        body["enable_thinking"] = Value::Bool(enable_thinking);
    }
    body
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
    let response_summary = summarize_openai_response(raw_response);
    extract_openai_message_content_inner(raw_response)
        .with_context(|| format!("OpenAI-compatible response contract failed: {response_summary}"))
}

fn extract_openai_message_content_inner(raw_response: &Value) -> Result<String> {
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

    let text = match content {
        Value::String(text) => text.clone(),
        Value::Array(parts) => {
            let text = parts
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
            if text.trim().is_empty() {
                Err(anyhow!(
                    "llm response content array did not contain text parts"
                ))
            } else {
                Ok(text)
            }?
        }
        _ => return Err(anyhow!("unsupported llm response content shape")),
    };
    if text.trim().is_empty() {
        return Err(anyhow!("llm response message content is empty"));
    }
    Ok(text)
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

/// 模型输出契约：时间只摘录原文片段（time_text），由代码统一换算。
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct LlmRecordPayload {
    direction: Option<RecordDirection>,
    amount: Option<f64>,
    currency: Option<String>,
    category: Option<String>,
    merchant: Option<String>,
    time_text: Option<String>,
    note: Option<String>,
    subscription_cycle: Option<SubscriptionCycle>,
    asset_info: Option<ParsedAssetInfo>,
}

impl LlmRecordPayload {
    fn into_payload(self, now: DateTime<Tz>) -> Result<ParsedRecordPayload> {
        let time_text = self
            .time_text
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty());
        let transaction_at = match (&self.asset_info, time_text) {
            (Some(_), _) => None,
            (None, None) => Some(now),
            (None, Some(text)) => Some(
                rule_parser::resolve_time(&text, now)?
                    .ok_or_else(|| anyhow!("LLM time_text 无法换算为时间：{text}"))?,
            ),
        };
        Ok(ParsedRecordPayload {
            direction: self.direction,
            amount: self.amount,
            currency: self.currency,
            category: self.category,
            merchant: self.merchant,
            transaction_at: transaction_at.map(|value| value.with_timezone(&Utc)),
            note: self.note,
            subscription_cycle: self.subscription_cycle,
            asset_info: self.asset_info,
        })
    }
}

pub(crate) fn parse_record_payloads_strict(
    content: &str,
    now: DateTime<Tz>,
) -> Result<Vec<ParsedRecordPayload>> {
    let trimmed = content.trim();
    let output_summary = summarize_text_output(content);
    let value: Value = serde_json::from_str(trimmed).map_err(|error| {
        anyhow!(
            "LLM response contains invalid JSON syntax: {}; {}; parser_error={error}",
            output_summary,
            summarize_json_error_location(trimmed, &error)
        )
    })?;
    let raw_payloads: Vec<LlmRecordPayload> =
        serde_path_to_error::deserialize(value).map_err(|error| {
        anyhow!(
            "LLM response JSON does not match the record contract: {}; error_path={}; parser_error={}",
            output_summary,
            error.path(),
            error.inner()
        )
    })?;
    if raw_payloads.is_empty() {
        return Err(anyhow!("LLM response contains no parsed records"));
    }
    let payloads = raw_payloads
        .into_iter()
        .map(|payload| payload.into_payload(now))
        .collect::<Result<Vec<_>>>()?;
    for payload in &payloads {
        validate_record_payload_contract(payload)?;
    }
    Ok(payloads)
}

fn summarize_openai_response(raw_response: &Value) -> String {
    let Some(choices) = raw_response.get("choices") else {
        return format!(
            "choices=missing top_level={}",
            summarize_json_value(raw_response)
        );
    };
    let Some(choices) = choices.as_array() else {
        return format!("choices={}", summarize_json_value(choices));
    };
    let Some(first) = choices.first() else {
        return "choices=array(count=0)".to_string();
    };
    let finish_reason = first
        .get("finish_reason")
        .map(summarize_finish_reason)
        .unwrap_or_else(|| "missing".to_string());
    let Some(message) = first.get("message") else {
        return format!(
            "choices=array(count={}) finish_reason={finish_reason} message=missing",
            choices.len()
        );
    };
    let message_keys = message
        .as_object()
        .map(|object| {
            let mut keys = object.keys().map(String::as_str).collect::<Vec<_>>();
            keys.sort_unstable();
            keys.join(",")
        })
        .unwrap_or_else(|| "not_an_object".to_string());
    let content = message
        .get("content")
        .map(summarize_json_value)
        .unwrap_or_else(|| "missing".to_string());
    let reasoning_content = message
        .get("reasoning_content")
        .map(summarize_json_value)
        .unwrap_or_else(|| "missing".to_string());
    let refusal = message
        .get("refusal")
        .map(summarize_json_value)
        .unwrap_or_else(|| "missing".to_string());
    format!(
        "choices=array(count={}) finish_reason={finish_reason} message_keys=[{message_keys}] content={content} reasoning_content={reasoning_content} refusal={refusal}",
        choices.len()
    )
}

fn summarize_provider_response(provider: &LlmProvider, raw_response: &Value) -> String {
    match provider {
        LlmProvider::OpenAi => summarize_openai_response(raw_response),
        LlmProvider::Anthropic => {
            let content = raw_response
                .get("content")
                .map(summarize_json_value)
                .unwrap_or_else(|| "missing".to_string());
            let stop_reason = raw_response
                .get("stop_reason")
                .map(summarize_finish_reason)
                .unwrap_or_else(|| "missing".to_string());
            format!("content={content} stop_reason={stop_reason}")
        }
    }
}

fn summarize_finish_reason(value: &Value) -> String {
    match value.as_str() {
        Some(
            "stop" | "length" | "content_filter" | "tool_calls" | "function_call" | "end_turn"
            | "max_tokens" | "stop_sequence",
        ) => value.as_str().expect("matched string").to_string(),
        _ => summarize_json_value(value),
    }
}

fn summarize_json_value(value: &Value) -> String {
    match value {
        Value::Null => "null".to_string(),
        Value::Bool(_) => "boolean".to_string(),
        Value::Number(_) => "number".to_string(),
        Value::String(text) => format!(
            "string(bytes={},trimmed_bytes={})",
            text.len(),
            text.trim().len()
        ),
        Value::Array(items) => format!("array(count={})", items.len()),
        Value::Object(object) => format!("object(keys={})", object.len()),
    }
}

fn summarize_text_output(text: &str) -> String {
    let trimmed = text.trim();
    let first = trimmed.chars().next().map(summarize_scalar);
    let last = trimmed.chars().next_back().map(summarize_scalar);
    format!(
        "bytes={} trimmed_bytes={} lines={} first_non_whitespace={} last_non_whitespace={}",
        text.len(),
        trimmed.len(),
        text.lines().count(),
        first.as_deref().unwrap_or("none"),
        last.as_deref().unwrap_or("none")
    )
}

fn summarize_json_error_location(text: &str, error: &serde_json::Error) -> String {
    let line = error.line();
    let column = error.column();
    let error_line = text.lines().nth(line.saturating_sub(1));
    let line_bytes = error_line.map(str::len).unwrap_or(0);
    let line_scalars = error_line.map(|value| value.chars().count()).unwrap_or(0);
    let scalar_at = error_line
        .and_then(|value| value.chars().nth(column.saturating_sub(1)))
        .map(summarize_scalar)
        .unwrap_or_else(|| "end_of_line".to_string());
    let previous_scalar = error_line
        .and_then(|value| {
            column
                .checked_sub(2)
                .and_then(|index| value.chars().nth(index))
        })
        .map(summarize_scalar)
        .unwrap_or_else(|| "none".to_string());
    format!(
        "error_line={line} error_column={column} error_line_bytes={line_bytes} error_line_scalars={line_scalars} scalar_at_error={scalar_at} previous_scalar={previous_scalar}"
    )
}

fn summarize_scalar(value: char) -> String {
    format!("U+{:04X}", value as u32)
}

pub(crate) fn validate_record_payload_contract(payload: &ParsedRecordPayload) -> Result<()> {
    if payload.asset_info.is_some() && payload.subscription_cycle.is_some() {
        return Err(anyhow!(
            "LLM payload cannot be both an asset and a subscription"
        ));
    }
    if let Some(amount) = payload.amount
        && (!amount.is_finite() || amount <= 0.0)
    {
        return Err(anyhow!(
            "LLM payload amount must be a finite positive number"
        ));
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
        if let Some(category) = asset.category.as_deref()
            && !is_valid_asset_category(category)
        {
            return Err(anyhow!("LLM asset payload category is invalid"));
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

    use crate::EntrySource;

    use super::{
        LlmConfig, LlmProvider, build_openai_request_body, build_record_prompt,
        extract_openai_message_content, normalize_currency_code, parse_llm_model_items,
        parse_record_payloads_strict,
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
    fn legacy_llm_config_keeps_provider_default_thinking_mode() {
        let config: LlmConfig = serde_json::from_value(json!({
            "base_url": "http://127.0.0.1:8081/v1",
            "api_key": "key",
            "model": "qwen3.6-flash",
            "provider": "openai_compatible"
        }))
        .unwrap();
        assert_eq!(config.enable_thinking, None);
    }

    #[test]
    fn openai_request_only_sends_thinking_mode_when_explicitly_configured() {
        let provider_default =
            build_openai_request_body("model", "system".to_string(), "user".to_string(), None);
        assert!(provider_default.get("enable_thinking").is_none());
        assert_eq!(provider_default["temperature"], json!(0));

        let disabled = build_openai_request_body(
            "model",
            "system".to_string(),
            "user".to_string(),
            Some(false),
        );
        assert_eq!(disabled["enable_thinking"], json!(false));
    }

    fn test_now() -> chrono::DateTime<chrono_tz::Tz> {
        use chrono::TimeZone;
        chrono_tz::Asia::Shanghai
            .with_ymd_and_hms(2026, 7, 14, 14, 38, 45)
            .unwrap()
    }

    #[test]
    fn record_prompt_leaves_time_arithmetic_to_code() {
        let prompt = build_record_prompt(&EntrySource::Text, None);
        assert!(prompt.contains("time_text：原文中描述交易时间的片段，原样摘录"));
        assert!(!prompt.contains("transaction_at"));
        assert!(!prompt.contains("{pinned_fields}"));
        assert!(!prompt.contains("{expense_categories}"));
        assert!(prompt.contains("服装、鞋靴、数码等实体商品用“购物”"));
    }

    #[test]
    fn record_prompt_includes_pinned_fields() {
        let prompt = build_record_prompt(
            &EntrySource::Text,
            Some("以下字段已由程序确定\n- amount: 25"),
        );
        assert!(prompt.contains("- amount: 25"));
    }

    #[test]
    fn record_prompt_distinguishes_ocr_evidence_without_assuming_a_page_style() {
        let prompt = build_record_prompt(&EntrySource::Ocr, None);

        assert!(prompt.contains("页面样式和 OCR 行顺序都不固定"));
        assert!(prompt.contains("必须依据字段标签、上下文语义和交易角色选择证据"));
        assert!(prompt.contains("设备状态栏时间、截图时间、页面更新时间不是交易时间"));
        assert!(prompt.contains("实际收款方、商户、店铺或服务提供方"));
        assert!(prompt.contains("存在商品或服务名称时，提取能区分交易的简短核心名称"));
        assert!(prompt.contains("订单、支付、履约、物流或退款流程状态"));
        assert!(prompt.contains("不能直接作为 note"));
        assert!(prompt.contains("不要用页面上最靠近金额的文字填充"));
        assert!(!prompt.contains("{input_source_rules}"));
    }

    #[test]
    fn text_prompt_does_not_receive_ocr_only_evidence_rules() {
        let prompt = build_record_prompt(&EntrySource::Text, None);

        assert!(prompt.contains("输入来自用户直接表述"));
        assert!(!prompt.contains("页面样式和 OCR 行顺序都不固定"));
        assert!(!prompt.contains("{input_source_rules}"));
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
            r#"[{"direction":"expense","amount":35,"currency":"CNY","category":"餐饮","merchant":null,"time_text":null,"note":null,"subscription_cycle":null,"asset_info":null}]"#,
            test_now(),
        )
        .unwrap();
        assert_eq!(payloads.len(), 1);
        assert_eq!(payloads[0].amount, Some(35.0));
    }

    #[test]
    fn strict_parser_rejects_markdown_and_nested_string_json() {
        assert!(parse_record_payloads_strict("```json\n[]\n```", test_now()).is_err());
        assert!(parse_record_payloads_strict(r#""[{\"direction\":null}]""#, test_now()).is_err());
    }

    #[test]
    fn strict_parser_reports_json_syntax_location_without_output_content() {
        let error = parse_record_payloads_strict("[\n  {\"direction\": \"expense\"\n]", test_now())
            .unwrap_err();
        let message = error.to_string();
        assert!(message.contains("invalid JSON syntax"));
        assert!(message.contains("error_line="));
        assert!(message.contains("error_column="));
        assert!(message.contains("scalar_at_error="));
        assert!(!message.contains("expense"));
    }

    #[test]
    fn strict_parser_distinguishes_valid_json_from_record_contract_failure() {
        let error =
            parse_record_payloads_strict(r#"[{"unexpected":true}]"#, test_now()).unwrap_err();
        let message = error.to_string();
        assert!(message.contains("JSON does not match the record contract"));
        assert!(message.contains("error_path=[0].unexpected"));
        assert!(message.contains("unknown field `unexpected`"));
        assert!(!message.contains(r#"{"unexpected":true}"#));
    }

    #[test]
    fn strict_parser_resolves_time_text_in_code() {
        let payloads = parse_record_payloads_strict(
            r#"[{"direction":"expense","amount":35,"currency":"CNY","category":"餐饮","merchant":null,"time_text":"昨天早上","note":null,"subscription_cycle":null,"asset_info":null}]"#,
            test_now(),
        )
        .unwrap();
        assert_eq!(
            payloads[0].transaction_at.unwrap().to_rfc3339(),
            "2026-07-13T00:00:00+00:00"
        );
    }

    #[test]
    fn strict_parser_uses_now_without_time_text_and_none_for_assets() {
        let payloads = parse_record_payloads_strict(
            r#"[{"direction":"expense","amount":35,"currency":"CNY","category":"餐饮","merchant":null,"time_text":null,"note":null,"subscription_cycle":null,"asset_info":null},{"direction":null,"amount":null,"currency":null,"category":null,"merchant":null,"time_text":null,"note":null,"subscription_cycle":null,"asset_info":{"name":"招商银行","category":"存款","amount":54000,"currency":"CNY","recorded_on":null,"note":null}}]"#,
            test_now(),
        )
        .unwrap();
        assert_eq!(
            payloads[0].transaction_at.unwrap().to_rfc3339(),
            "2026-07-14T06:38:45+00:00"
        );
        assert!(payloads[1].transaction_at.is_none());
    }

    #[test]
    fn strict_parser_rejects_unresolvable_time_text_and_legacy_transaction_at() {
        let error = parse_record_payloads_strict(
            r#"[{"direction":"expense","amount":35,"currency":"CNY","category":"餐饮","merchant":null,"time_text":"最近","note":null,"subscription_cycle":null,"asset_info":null}]"#,
            test_now(),
        )
        .unwrap_err();
        assert!(error.to_string().contains("time_text 无法换算"));

        let error = parse_record_payloads_strict(
            r#"[{"direction":"expense","amount":35,"currency":"CNY","category":"餐饮","merchant":null,"transaction_at":"2026-07-14","note":null,"subscription_cycle":null,"asset_info":null}]"#,
            test_now(),
        )
        .unwrap_err();
        assert!(error.to_string().contains("error_path=[0].transaction_at"));
    }

    #[test]
    fn openai_extractor_reports_empty_content_and_finish_reason() {
        let response = json!({
            "choices": [{
                "finish_reason": "length",
                "message": {
                    "role": "assistant",
                    "content": "",
                    "reasoning_content": "internal reasoning"
                }
            }]
        });
        let error = extract_openai_message_content(&response).unwrap_err();
        let message = format!("{error:#}");
        assert!(message.contains("message content is empty"));
        assert!(message.contains("finish_reason=length"));
        assert!(message.contains("content=string(bytes=0,trimmed_bytes=0)"));
        assert!(message.contains("reasoning_content=string(bytes=18,trimmed_bytes=18)"));
        assert!(!message.contains("internal reasoning"));
    }

    #[test]
    fn openai_extractor_accepts_non_empty_text_content() {
        let response = json!({
            "choices": [{
                "finish_reason": "stop",
                "message": {"role": "assistant", "content": "[{\"ok\":true}]"}
            }]
        });
        let content = extract_openai_message_content(&response).unwrap();
        assert_eq!(content, "[{\"ok\":true}]");
    }

    #[test]
    fn strict_parser_rejects_currency_aliases() {
        assert!(
            parse_record_payloads_strict(
                r#"[{"direction":"expense","amount":12,"currency":"美元","category":"餐饮","merchant":null,"time_text":null,"note":null,"subscription_cycle":null,"asset_info":null}]"#,
                test_now(),
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
