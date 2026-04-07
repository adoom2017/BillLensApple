use std::{env, fmt};

use anyhow::{Context, Result, anyhow};
use billlens_apple_db::{
    EXPENSE_CATEGORIES, INCOME_CATEGORIES, ParsedRecordPayload, RecordDirection, RecordDraft,
    is_valid_record_category, is_valid_record_category_for_direction,
};
use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, Offset, TimeZone, Utc};
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::logger;

const RECORD_PROMPT_TEMPLATE: &str = r#"你是一个消费记录结构化助手。请将用户输入解析为 JSON。
今天的日期是：{today}
当前的时间是：{current_time}
必须严格返回 JSON，不要输出解释文字，不要输出 markdown。
category 只能从以下固定分类中选择：
- 支出：{expense_categories}
- 收入：{income_categories}
如果无法判断分类，使用“其他”。
如果文本明确出现“退款”“退回”“退费”“退款成功”等语义，应判断为收入，分类优先使用“其他”。
amount 必须始终返回正数，不要返回负数；收支方向只放在 direction 字段里表达。
只有当原始输入中明确出现时间线索时，才填写 transaction_at；如果原始输入没有体现任何时间信息，transaction_at 必须直接使用当前完整时间，精确到秒，不要只返回日期，不要返回当天 0 点，不要猜测、不要编造。
如果时间缺少时区，不要臆造 Z 或 UTC；优先返回原始本地时间字符串。
note 只保留与交易本身直接相关的简短备注；忽略积分、贴纸、奖励、营销文案、活动提示；如果没有合适备注，返回 null。
JSON 格式如下：
{
  "direction": "income" | "expense" | null,
  "amount": number | null,
  "currency": "CNY" | string | null,
  "category": string | null,
  "merchant": string | null,
  "transaction_at": "RFC3339 datetime" | null,
  "note": string | null
}"#;

#[allow(dead_code)]
const RECORD_PATCH_PROMPT_TEMPLATE: &str = r#"你是一个记账草稿修改助手。你会看到当前草稿和用户最新一句修改指令。
今天的日期是：{today}
当前的时间是：{current_time}
当前草稿如下：
{draft_json}

任务要求：
- 只提取用户这一次明确要求修改的字段
- 没有被这次指令明确修改的字段，一律返回 null
- 不要把当前草稿里的原值抄回输出
- 如果用户只是说“把金额改成35元”，只返回 amount=35，其他字段返回 null
- 只有用户明确要求把收入改成支出、或支出改成收入时，才填写 direction
- category 只能从以下固定分类中选择：
  - 支出：{expense_categories}
  - 收入：{income_categories}
- 如果用户没有明确修改分类，不要猜测分类
- amount 必须始终返回正数，不要返回负数
- 如果用户没有明确修改时间，不要补时间，transaction_at 返回 null
- note 只在用户明确要求修改备注时填写；否则返回 null
- 必须严格返回 JSON，不要输出解释文字，不要输出 markdown
JSON 格式如下：
{
  "direction": "income" | "expense" | null,
  "amount": number | null,
  "currency": "CNY" | string | null,
  "category": string | null,
  "merchant": string | null,
  "transaction_at": "RFC3339 datetime" | null,
  "note": string | null
}"#;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmConfig {
    pub base_url: String,
    pub api_key: String,
    pub model: String,
    pub provider: String,
}

impl LlmConfig {
    pub fn from_env_optional() -> Result<Option<Self>> {
        let base_url = env::var("LLM_BASE_URL").ok();
        let api_key = env::var("LLM_API_KEY").ok();
        let model = env::var("LLM_MODEL").ok();
        let provider = env::var("LLM_PROVIDER").unwrap_or_else(|_| "openai".to_string());

        match (base_url, api_key, model) {
            (Some(base_url), Some(api_key), Some(model)) => Ok(Some(Self {
                base_url,
                api_key,
                model,
                provider,
            })),
            (None, None, None) => Ok(None),
            _ => Err(anyhow!(
                "LLM_BASE_URL, LLM_API_KEY and LLM_MODEL must be provided together"
            )),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LlmProvider {
    OpenAi,
    Anthropic,
    LlamaCpp,
}

impl LlmProvider {
    pub fn parse(value: &str) -> Result<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "openai" => Ok(Self::OpenAi),
            "anthropic" => Ok(Self::Anthropic),
            "llamacpp" => Ok(Self::LlamaCpp),
            _ => Err(anyhow!("unsupported llm provider")),
        }
    }
}

impl fmt::Display for LlmProvider {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let value = match self {
            Self::OpenAi => "openai",
            Self::Anthropic => "anthropic",
            Self::LlamaCpp => "llamacpp",
        };
        f.write_str(value)
    }
}

#[derive(Clone)]
pub struct LlmClient {
    http: reqwest::Client,
    base_url: String,
    api_key: String,
    model: String,
    provider: LlmProvider,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NoteFallbackMode {
    PreserveInputText,
    SkipInputText,
}

impl LlmClient {
    pub fn from_config(config: LlmConfig) -> Result<Self> {
        let provider = LlmProvider::parse(&config.provider).context("invalid LLM_PROVIDER")?;
        Ok(Self::new(
            config.base_url,
            config.api_key,
            config.model,
            provider,
        ))
    }

    pub fn new(base_url: String, api_key: String, model: String, provider: LlmProvider) -> Self {
        Self {
            http: reqwest::Client::new(),
            base_url,
            api_key,
            model,
            provider,
        }
    }

    pub async fn parse_record_text(&self, text: String) -> Result<ParsedRecordPayload> {
        self.parse_record_text_with_options(text, NoteFallbackMode::PreserveInputText)
            .await
    }

    pub async fn parse_record_ocr_text(&self, text: String) -> Result<ParsedRecordPayload> {
        self.parse_record_text_with_options(text, NoteFallbackMode::SkipInputText)
            .await
    }

    #[allow(dead_code)]
    pub async fn parse_record_patch_text(
        &self,
        text: String,
        draft: &RecordDraft,
    ) -> Result<ParsedRecordPayload> {
        let prompt = build_record_patch_prompt(draft);
        let response = self.send_prompted_request(prompt, text).await?;
        let raw_response: Value = response
            .json()
            .await
            .context("failed to decode llm response")?;
        let content = extract_message_content(&self.provider, &raw_response)?;
        let mut payload = parse_record_payload_text(&content)?;
        finalize_record_patch_payload(&mut payload);
        Ok(payload)
    }

    async fn parse_record_text_with_options(
        &self,
        text: String,
        note_fallback_mode: NoteFallbackMode,
    ) -> Result<ParsedRecordPayload> {
        let prompt = build_record_prompt();
        logger::info(
            "llm.request",
            format!(
                "provider={} model={} mode={note_fallback_mode:?} prompt={} input={}",
                self.provider,
                self.model,
                truncate_for_log(&prompt, 2000),
                truncate_for_log(&text, 4000)
            ),
        );
        let response = self.send_prompted_request(prompt, text.clone()).await?;
        let raw_response_text = response
            .text()
            .await
            .context("failed to read llm response body")?;
        logger::info(
            "llm.response",
            format!(
                "provider={} model={} raw={}",
                self.provider,
                self.model,
                truncate_for_log(&raw_response_text, 6000)
            ),
        );
        let raw_response: Value =
            serde_json::from_str(&raw_response_text).context("failed to decode llm response")?;
        let content = extract_message_content(&self.provider, &raw_response)?;
        logger::info(
            "llm.response.content",
            truncate_for_log(&content, 4000),
        );
        let mut payload = parse_record_payload_text(&content)?;
        finalize_record_payload(&mut payload, &text, note_fallback_mode);
        logger::info(
            "llm.response.parsed",
            serde_json::to_string(&payload).unwrap_or_else(|_| "<serialize failed>".to_string()),
        );
        Ok(payload)
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
            LlmProvider::LlamaCpp => (
                "/chat/completions",
                build_llamacpp_request_body(&self.model, system_prompt, text),
            ),
            LlmProvider::Anthropic => (
                "/messages",
                build_anthropic_request_body(&self.model, system_prompt, text),
            ),
        };

        let url = format!(
            "{}/{}",
            self.base_url.trim_end_matches('/'),
            path.trim_start_matches('/')
        );
        logger::info(
            "llm.http",
            format!(
                "url={} body={}",
                url,
                truncate_for_log(&body.to_string(), 6000)
            ),
        );
        let request = self.http.post(url).header(CONTENT_TYPE, "application/json");
        let request = match self.provider {
            LlmProvider::OpenAi | LlmProvider::LlamaCpp => {
                if self.api_key.trim().is_empty() {
                    request
                } else {
                    request.header(AUTHORIZATION, format!("Bearer {}", self.api_key))
                }
            }
            LlmProvider::Anthropic => request
                .header("x-api-key", &self.api_key)
                .header("anthropic-version", "2023-06-01"),
        };

        request
            .json(&body)
            .send()
            .await
            .context("failed to call llm provider")?
            .error_for_status()
            .context("llm provider returned error status")
    }
}

fn truncate_for_log(value: &str, max_chars: usize) -> String {
    let mut chars = value.chars();
    let truncated: String = chars.by_ref().take(max_chars).collect();
    if chars.next().is_some() {
        format!("{truncated}…")
    } else {
        truncated
    }
}

fn build_record_prompt() -> String {
    RECORD_PROMPT_TEMPLATE
        .replace("{today}", &Utc::now().format("%Y-%m-%d").to_string())
        .replace(
            "{current_time}",
            &Local::now().format("%Y-%m-%d %H:%M:%S").to_string(),
        )
        .replace("{expense_categories}", &EXPENSE_CATEGORIES.join("、"))
        .replace("{income_categories}", &INCOME_CATEGORIES.join("、"))
}

#[allow(dead_code)]
fn build_record_patch_prompt(draft: &RecordDraft) -> String {
    let draft_json = serde_json::json!({
        "direction": draft.direction.as_ref().map(RecordDirection::as_str),
        "amount": draft.amount,
        "currency": draft.currency,
        "category": draft.category,
        "merchant": draft.merchant,
        "transaction_at": draft.transaction_at.map(|value| value.to_rfc3339()),
        "note": draft.note,
    });
    RECORD_PATCH_PROMPT_TEMPLATE
        .replace("{today}", &Utc::now().format("%Y-%m-%d").to_string())
        .replace(
            "{current_time}",
            &Local::now().format("%Y-%m-%d %H:%M:%S").to_string(),
        )
        .replace("{draft_json}", &draft_json.to_string())
        .replace("{expense_categories}", &EXPENSE_CATEGORIES.join("、"))
        .replace("{income_categories}", &INCOME_CATEGORIES.join("、"))
}

fn build_openai_request_body(model: &str, system_prompt: String, text: String) -> Value {
    json!({
        "model": model,
        "reasoning_split": true,
        "stream": false,
        "max_tokens": 512,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": text}
        ]
    })
}

fn build_llamacpp_request_body(model: &str, system_prompt: String, text: String) -> Value {
    json!({
        "model": model,
        "stream": false,
        "max_tokens": 512,
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
        "max_tokens": 1024,
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
        LlmProvider::OpenAi | LlmProvider::LlamaCpp => extract_openai_message_content(raw_response),
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
                Err(anyhow!("llm response content array did not contain text parts"))
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

fn normalize_json_payload(content: &str) -> String {
    let cleaned = strip_think_blocks(content);
    let trimmed = cleaned.trim();
    if let Some(stripped) = trimmed.strip_prefix("```json") {
        return extract_json_object(stripped.trim().trim_end_matches("```").trim())
            .unwrap_or_else(|| stripped.trim().trim_end_matches("```").trim().to_string());
    }
    if let Some(stripped) = trimmed.strip_prefix("```") {
        return extract_json_object(stripped.trim().trim_end_matches("```").trim())
            .unwrap_or_else(|| stripped.trim().trim_end_matches("```").trim().to_string());
    }
    extract_json_object(trimmed).unwrap_or_else(|| trimmed.to_string())
}

fn parse_record_payload_text(content: &str) -> Result<ParsedRecordPayload> {
    let normalized = normalize_json_payload(content);
    let json_value: Value = serde_json::from_str(&normalized)
        .or_else(|_| serde_json::from_str::<String>(content.trim()).map(Value::String))
        .context("failed to parse llm record json payload")?;
    let object_value = coerce_json_object_value(json_value)?;
    parse_record_payload_value(object_value)
}

fn coerce_json_object_value(value: Value) -> Result<Value> {
    match value {
        Value::String(text) => {
            let normalized = normalize_json_payload(&text);
            let nested: Value = serde_json::from_str(&normalized)
                .context("failed to parse nested llm record json payload")?;
            coerce_json_object_value(nested)
        }
        Value::Array(mut values) if values.len() == 1 => {
            let nested = values.remove(0);
            coerce_json_object_value(nested)
        }
        other => Ok(other),
    }
}

fn strip_think_blocks(content: &str) -> String {
    let mut output = String::with_capacity(content.len());
    let mut remaining = content;
    loop {
        let Some(start) = remaining.find("<think>") else {
            output.push_str(remaining);
            break;
        };
        output.push_str(&remaining[..start]);
        let after_start = &remaining[start + "<think>".len()..];
        let Some(end) = after_start.find("</think>") else {
            break;
        };
        remaining = &after_start[end + "</think>".len()..];
    }
    output
}

fn extract_json_object(content: &str) -> Option<String> {
    let start = content.find('{')?;
    let end = content.rfind('}')?;
    (start < end).then(|| content[start..=end].trim().to_string())
}

fn parse_record_payload_value(value: Value) -> Result<ParsedRecordPayload> {
    let object = value
        .as_object()
        .ok_or_else(|| anyhow!("llm record payload is not a json object"))?;

    let direction = object
        .get("direction")
        .and_then(Value::as_str)
        .and_then(|value| RecordDirection::try_from(value).ok());
    let amount = object
        .get("amount")
        .and_then(|value| match value {
            Value::Number(number) => number.as_f64(),
            Value::String(text) => text.parse::<f64>().ok(),
            _ => None,
        })
        .map(f64::abs);
    let currency = object
        .get("currency")
        .and_then(Value::as_str)
        .map(ToString::to_string);
    let category = object
        .get("category")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string);
    let merchant = object
        .get("merchant")
        .and_then(Value::as_str)
        .map(ToString::to_string);
    let transaction_at = object
        .get("transaction_at")
        .or_else(|| object.get("transaction_date"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(parse_record_datetime)
        .transpose()?;
    let note = object
        .get("note")
        .and_then(Value::as_str)
        .map(ToString::to_string)
        .and_then(|value| sanitize_note(&value));

    let category = match category {
        Some(category) if !is_valid_record_category(&category) => None,
        Some(category)
            if direction.as_ref().is_some_and(|direction| {
                !is_valid_record_category_for_direction(Some(direction), &category)
            }) =>
        {
            None
        }
        category => category,
    };

    Ok(ParsedRecordPayload {
        direction,
        amount,
        currency,
        category,
        merchant,
        transaction_at,
        note,
    })
}

fn finalize_record_payload(
    payload: &mut ParsedRecordPayload,
    raw_text: &str,
    note_fallback_mode: NoteFallbackMode,
) {
    apply_record_inference_hints(payload, raw_text);
    normalize_record_fields(payload, raw_text);
    if payload.note.as_deref().is_none_or(str::is_empty)
        && matches!(note_fallback_mode, NoteFallbackMode::PreserveInputText)
    {
        let trimmed = raw_text.trim();
        if !trimmed.is_empty() {
            payload.note = Some(trimmed.to_string());
        }
    }
    if payload.transaction_at.is_none() {
        payload.transaction_at = Some(current_service_time());
    }
}

#[allow(dead_code)]
fn finalize_record_patch_payload(payload: &mut ParsedRecordPayload) {
    if let Some(amount) = payload.amount {
        payload.amount = Some(amount.abs());
    }
    if let Some(merchant) = payload.merchant.as_mut() {
        *merchant = clean_merchant(merchant);
    }
    if let Some(note) = payload.note.as_deref() {
        payload.note = sanitize_note(note);
    }
    if let Some(category) = payload.category.as_deref() {
        if !is_valid_record_category(category) {
            payload.category = None;
        } else if payload.direction.as_ref().is_some_and(|direction| {
            !is_valid_record_category_for_direction(Some(direction), category)
        }) {
            payload.category = None;
        }
    }
}

fn apply_record_inference_hints(payload: &mut ParsedRecordPayload, raw_text: &str) {
    let normalized = raw_text.replace(char::is_whitespace, "");
    let explicit_refund_like = [
        "退款成功",
        "退款方式",
        "退款-",
        "退回",
        "退费",
        "银行处理成功",
    ]
    .iter()
    .any(|keyword| normalized.contains(keyword));
    let expense_like = [
        "交易成功",
        "支付时间",
        "付款方式",
        "支付机构",
        "收单机构",
        "小额免密支付",
        "商家订单号",
        "等待确认收货",
    ]
    .iter()
    .any(|keyword| normalized.contains(keyword));
    let has_negative_amount_marker =
        normalized.contains("-") || normalized.contains("￥-") || normalized.contains("¥-");

    if explicit_refund_like && !expense_like {
        payload.direction = Some(RecordDirection::Income);
        if payload.category.as_deref().is_none_or(str::is_empty)
            || !is_valid_record_category_for_direction(
                payload.direction.as_ref(),
                payload.category.as_deref().unwrap_or(""),
            )
        {
            payload.category = Some("其他".to_string());
        }
    } else if expense_like || has_negative_amount_marker {
        payload.direction = Some(RecordDirection::Expense);
        if payload.category.as_deref().is_some_and(|category| {
            !is_valid_record_category_for_direction(payload.direction.as_ref(), category)
        }) {
            payload.category = None;
        }
    }

    if let Some(amount) = payload.amount {
        payload.amount = Some(amount.abs());
    }
}

fn normalize_record_fields(payload: &mut ParsedRecordPayload, raw_text: &str) {
    let inferred_category = infer_category(raw_text, payload.direction.as_ref());
    if payload.category.as_deref().is_none_or(str::is_empty) {
        payload.category = inferred_category;
    } else if payload.category.as_deref() == Some("其他") {
        if let Some(inferred_category) = inferred_category {
            if inferred_category != "其他" {
                payload.category = Some(inferred_category);
            }
        }
    }

    if payload.merchant.as_deref().is_none_or(str::is_empty) {
        payload.merchant = infer_merchant(raw_text);
    } else if let Some(merchant) = payload.merchant.as_mut() {
        *merchant = clean_merchant(merchant);
    }

    if payload.transaction_at.is_none() {
        payload.transaction_at = Some(current_service_time());
    }

    if let Some(note) = payload.note.as_deref() {
        payload.note = sanitize_note(note);
    }
}

fn sanitize_note(note: &str) -> Option<String> {
    let normalized = note.trim();
    if normalized.is_empty() {
        return None;
    }

    let blocked_keywords = [
        "贴纸", "积分", "奖励", "解锁", "领取", "活动", "优惠", "返现", "勋章", "成就",
    ];
    if blocked_keywords
        .iter()
        .any(|keyword| normalized.contains(keyword))
    {
        return None;
    }

    Some(normalized.to_string())
}

fn infer_category(raw_text: &str, direction: Option<&RecordDirection>) -> Option<String> {
    let normalized = raw_text.replace(char::is_whitespace, "");
    if matches!(direction, Some(RecordDirection::Income)) {
        if normalized.contains("投资")
            || normalized.contains("理财")
            || normalized.contains("基金")
            || normalized.contains("分红")
        {
            return Some("投资收益".to_string());
        }
        if normalized.contains("工资") || normalized.contains("奖金") || normalized.contains("薪资")
        {
            return Some("工资收入".to_string());
        }
        return Some("其他".to_string());
    }

    let mappings: &[(&[&str], &str)] = &[
        (&["餐饮", "外卖", "饭店", "牛肉馆", "咖啡", "奶茶"], "餐饮"),
        (&["打车", "地铁", "公交", "高铁", "机票", "加油"], "交通"),
        (&["超市", "日用", "洗衣液", "纸巾", "牙刷"], "日用"),
        (
            &[
                "天猫",
                "淘宝",
                "京东",
                "拼多多",
                "运动户外",
                "服饰装扮",
                "鞋",
                "衣服",
                "裤",
            ],
            "购物",
        ),
        (&["房租", "物业", "水费", "电费", "燃气"], "住房"),
        (&["医院", "药店", "挂号", "体检", "医保"], "医疗"),
        (&["电影", "演出", "门票", "游戏", "KTV", "旅游"], "娱乐"),
        (&["课程", "培训", "学费", "考试", "教材"], "教育"),
        (&["话费", "宽带", "通信", "流量", "会员"], "通讯"),
        (&["红包", "礼金", "礼物", "份子", "捐赠"], "人情"),
    ];

    for (keywords, category) in mappings {
        if keywords.iter().any(|keyword| normalized.contains(keyword)) {
            return Some(category.to_string());
        }
    }

    None
}

fn infer_merchant(raw_text: &str) -> Option<String> {
    let lines = raw_text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty());
    for line in lines {
        let cleaned = clean_merchant(line);
        if looks_like_merchant(&cleaned) {
            return Some(cleaned);
        }
    }
    None
}

fn clean_merchant(value: &str) -> String {
    let mut cleaned = value.trim().to_string();
    for prefix in ["天猫-", "淘宝-", "京东-", "支付宝-", "微信支付-"] {
        if let Some(stripped) = cleaned.strip_prefix(prefix) {
            cleaned = stripped.to_string();
        }
    }
    for token in ["天猫", "淘宝", "京东", "支付宝", "微信支付", "微信"] {
        if cleaned == token {
            return String::new();
        }
    }
    cleaned = cleaned.replace("**", "");
    cleaned = cleaned.replace('*', "");
    cleaned = cleaned.replace('>', "");
    cleaned = cleaned.replace('（', "(").replace('）', ")");
    cleaned = cleaned
        .trim_matches(|c: char| c == '-' || c == '·' || c == ':' || c == '：')
        .trim()
        .to_string();
    cleaned
}

fn looks_like_merchant(value: &str) -> bool {
    if value.is_empty() || value.chars().count() < 2 {
        return false;
    }
    let blocked = [
        "账单详情",
        "支付时间",
        "付款方式",
        "支付奖励",
        "交易详情",
        "订单号",
        "商家订单号",
        "账单管理",
        "账单分类",
        "标签",
        "请选择",
        "等待确认收货",
        "管理自动扣款",
        "淘宝小额免密支付",
        "立即领取5积分",
    ];
    !blocked.iter().any(|item| value.contains(item))
        && (value.contains('店')
            || value.contains("馆")
            || value.contains("超市")
            || value.contains("学园")
            || value.contains("商行")
            || value.chars().count() <= 12)
}

fn current_service_time() -> DateTime<Utc> {
    Local::now().with_timezone(&Utc)
}

fn parse_record_datetime(value: &str) -> Result<DateTime<Utc>> {
    let trimmed = value.trim();
    let normalized = trimmed.to_ascii_lowercase();
    let local_offset = Local::now().offset().fix();

    if matches!(normalized.as_str(), "today" | "now") || trimmed == "今天" {
        return Ok(Local::now().with_timezone(&Utc));
    }
    if normalized == "yesterday" || trimmed == "昨天" {
        return Ok((Local::now() - Duration::days(1)).with_timezone(&Utc));
    }
    if normalized == "tomorrow" || trimmed == "明天" {
        return Ok((Local::now() + Duration::days(1)).with_timezone(&Utc));
    }
    if let Ok(datetime) = DateTime::parse_from_rfc3339(trimmed) {
        return Ok(datetime.with_timezone(&Utc));
    }
    if let Ok(naive) = chrono::NaiveDateTime::parse_from_str(trimmed, "%Y-%m-%dT%H:%M:%S") {
        return Ok(local_offset.from_local_datetime(&naive).single().unwrap().with_timezone(&Utc));
    }
    if let Ok(date) = NaiveDate::parse_from_str(trimmed, "%Y-%m-%d") {
        return Ok(local_offset
            .with_ymd_and_hms(date.year(), date.month(), date.day(), 0, 0, 0)
            .single()
            .unwrap()
            .with_timezone(&Utc));
    }
    if let Ok(naive) = chrono::NaiveDateTime::parse_from_str(trimmed, "%Y-%m-%d%H:%M:%S") {
        return Ok(local_offset.from_local_datetime(&naive).single().unwrap().with_timezone(&Utc));
    }
    if let Ok(naive) = chrono::NaiveDateTime::parse_from_str(trimmed, "%Y-%m-%d %H:%M:%S") {
        return Ok(local_offset.from_local_datetime(&naive).single().unwrap().with_timezone(&Utc));
    }

    Err(anyhow!("invalid transaction_at format"))
}

#[cfg(test)]
mod tests {
    use super::{LlmProvider, clean_merchant, normalize_json_payload, parse_record_payload_text};

    #[test]
    fn provider_parse_supports_original_values() {
        assert!(matches!(LlmProvider::parse("openai").unwrap(), LlmProvider::OpenAi));
        assert!(matches!(LlmProvider::parse("llamacpp").unwrap(), LlmProvider::LlamaCpp));
        assert!(matches!(LlmProvider::parse("anthropic").unwrap(), LlmProvider::Anthropic));
    }

    #[test]
    fn normalize_payload_strips_think_blocks() {
        let normalized = normalize_json_payload(
            "<think>internal reasoning</think>\n```json\n{\"amount\":1,\"direction\":\"expense\"}\n```",
        );
        assert_eq!(normalized, "{\"amount\":1,\"direction\":\"expense\"}");
    }

    #[test]
    fn parse_record_payload_accepts_string_json() {
        let payload = parse_record_payload_text("\"{\\\"direction\\\":\\\"expense\\\",\\\"amount\\\":35,\\\"category\\\":\\\"餐饮\\\"}\"").unwrap();
        assert_eq!(payload.amount, Some(35.0));
        assert_eq!(payload.category.as_deref(), Some("餐饮"));
    }

    #[test]
    fn clean_merchant_matches_original_behavior() {
        assert_eq!(clean_merchant("天猫-舞云**店"), "舞云店");
    }
}
