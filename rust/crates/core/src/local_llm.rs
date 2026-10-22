use anyhow::{Context, Result, anyhow};
use billlens_apple_db::{ALL_RECORD_CATEGORIES, ASSET_CATEGORIES};
use serde::{Deserialize, Serialize};
use std::ffi::{CStr, CString, c_char};
use std::sync::OnceLock;

pub type LocalLlmRunFn = unsafe extern "C" fn(*const c_char) -> *mut c_char;
pub type LocalLlmCancelFn = unsafe extern "C" fn();
pub type LocalLlmUnloadFn = unsafe extern "C" fn();
pub type LocalLlmFreeStringFn = unsafe extern "C" fn(*mut c_char);

#[derive(Clone, Copy)]
pub struct LocalLlmBackend {
    pub run: LocalLlmRunFn,
    pub cancel: LocalLlmCancelFn,
    pub unload: LocalLlmUnloadFn,
    pub free_string: LocalLlmFreeStringFn,
}

unsafe impl Send for LocalLlmBackend {}
unsafe impl Sync for LocalLlmBackend {}

static BACKEND: OnceLock<LocalLlmBackend> = OnceLock::new();

pub fn register(backend: LocalLlmBackend) -> Result<()> {
    BACKEND
        .set(backend)
        .map_err(|_| anyhow!("local LLM backend is already registered"))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocalLlmRequest {
    pub schema_version: u32,
    pub model_id: String,
    pub system_prompt: String,
    pub user_text: String,
    pub grammar: String,
    pub context_tokens: u32,
    pub max_output_tokens: u32,
    pub deadline_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case", deny_unknown_fields)]
enum LocalLlmResponse {
    Success {
        schema_version: u32,
        model_id: String,
        content: String,
        elapsed_ms: u64,
    },
    Error {
        schema_version: u32,
        code: LocalLlmErrorCode,
        message: String,
    },
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LocalLlmErrorCode {
    BackendUnavailable,
    Disabled,
    ModelNotInstalled,
    ModelBusy,
    LoadFailed,
    OutOfMemory,
    InferenceFailed,
    Timeout,
    InvalidRuntimeRequest,
    InvalidRuntimeResponse,
    UnsupportedChatTemplate,
    Cancelled,
    AppBackgrounded,
    MemoryPressure,
}

impl LocalLlmErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::BackendUnavailable => "backend_unavailable",
            Self::Disabled => "disabled",
            Self::ModelNotInstalled => "model_not_installed",
            Self::ModelBusy => "model_busy",
            Self::LoadFailed => "load_failed",
            Self::OutOfMemory => "out_of_memory",
            Self::InferenceFailed => "inference_failed",
            Self::Timeout => "timeout",
            Self::InvalidRuntimeRequest => "invalid_runtime_request",
            Self::InvalidRuntimeResponse => "invalid_runtime_response",
            Self::UnsupportedChatTemplate => "unsupported_chat_template",
            Self::Cancelled => "cancelled",
            Self::AppBackgrounded => "app_backgrounded",
            Self::MemoryPressure => "memory_pressure",
        }
    }

    pub fn allows_cloud_fallback(self) -> bool {
        matches!(
            self,
            Self::ModelNotInstalled
                | Self::LoadFailed
                | Self::OutOfMemory
                | Self::InferenceFailed
                | Self::Timeout
                | Self::InvalidRuntimeResponse
                | Self::UnsupportedChatTemplate
        )
    }
}

#[derive(Debug, thiserror::Error)]
#[error("local LLM {code:?}: {message}")]
pub struct LocalLlmError {
    pub code: LocalLlmErrorCode,
    pub message: String,
}

impl LocalLlmError {
    fn new(code: LocalLlmErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

pub async fn run(request: LocalLlmRequest) -> Result<(String, String, u64), LocalLlmError> {
    let backend = BACKEND.get().copied().ok_or_else(|| {
        LocalLlmError::new(
            LocalLlmErrorCode::BackendUnavailable,
            "local LLM backend is not registered",
        )
    })?;
    tokio::task::spawn_blocking(move || run_blocking(backend, request))
        .await
        .map_err(|error| {
            LocalLlmError::new(
                LocalLlmErrorCode::InvalidRuntimeResponse,
                format!("local LLM worker failed: {error}"),
            )
        })?
}

fn run_blocking(
    backend: LocalLlmBackend,
    request: LocalLlmRequest,
) -> Result<(String, String, u64), LocalLlmError> {
    let request_json = serde_json::to_string(&request).map_err(|error| {
        LocalLlmError::new(
            LocalLlmErrorCode::InvalidRuntimeResponse,
            format!("failed to encode local LLM request: {error}"),
        )
    })?;
    let request_c = CString::new(request_json).map_err(|error| {
        LocalLlmError::new(
            LocalLlmErrorCode::InvalidRuntimeResponse,
            format!("local LLM request contains NUL: {error}"),
        )
    })?;
    let response_ptr = unsafe { (backend.run)(request_c.as_ptr()) };
    if response_ptr.is_null() {
        return Err(LocalLlmError::new(
            LocalLlmErrorCode::InvalidRuntimeResponse,
            "local LLM backend returned a null response",
        ));
    }
    let response_text = unsafe { CStr::from_ptr(response_ptr) }
        .to_str()
        .map(ToOwned::to_owned)
        .context("local LLM response is not valid UTF-8")
        .map_err(|error| {
            LocalLlmError::new(LocalLlmErrorCode::InvalidRuntimeResponse, error.to_string())
        });
    unsafe { (backend.free_string)(response_ptr) };
    let response_text = response_text?;
    let response: LocalLlmResponse = serde_json::from_str(&response_text).map_err(|error| {
        LocalLlmError::new(
            LocalLlmErrorCode::InvalidRuntimeResponse,
            format!("failed to decode local LLM response: {error}"),
        )
    })?;
    match response {
        LocalLlmResponse::Success {
            schema_version,
            model_id,
            content,
            elapsed_ms,
        } => {
            if schema_version != 1 {
                return Err(LocalLlmError::new(
                    LocalLlmErrorCode::InvalidRuntimeResponse,
                    format!("unsupported local LLM response schema: {schema_version}"),
                ));
            }
            if model_id != request.model_id {
                return Err(LocalLlmError::new(
                    LocalLlmErrorCode::InvalidRuntimeResponse,
                    "local LLM response model does not match request",
                ));
            }
            if content.trim().is_empty() {
                return Err(LocalLlmError::new(
                    LocalLlmErrorCode::InvalidRuntimeResponse,
                    "local LLM returned empty content",
                ));
            }
            Ok((content, model_id, elapsed_ms))
        }
        LocalLlmResponse::Error {
            schema_version,
            code,
            message,
        } => {
            if schema_version != 1 {
                return Err(LocalLlmError::new(
                    LocalLlmErrorCode::InvalidRuntimeResponse,
                    format!("unsupported local LLM error schema: {schema_version}"),
                ));
            }
            if message.trim().is_empty() {
                return Err(LocalLlmError::new(
                    LocalLlmErrorCode::InvalidRuntimeResponse,
                    "local LLM returned an error without a message",
                ));
            }
            Err(LocalLlmError::new(code, message))
        }
    }
}

pub fn cancel() -> Result<()> {
    let backend = BACKEND
        .get()
        .ok_or_else(|| anyhow!("local LLM backend is not registered"))?;
    unsafe { (backend.cancel)() };
    Ok(())
}

pub fn unload() -> Result<()> {
    let backend = BACKEND
        .get()
        .ok_or_else(|| anyhow!("local LLM backend is not registered"))?;
    unsafe { (backend.unload)() };
    Ok(())
}

const RECORD_JSON_GRAMMAR_TEMPLATE: &str = r#"
root ::= ws "[" ws (record (ws "," ws record)*)? ws "]" ws
record ::= "{" ws direction-field "," ws amount-field "," ws currency-field "," ws category-field "," ws merchant-field "," ws time-field "," ws note-field "," ws cycle-field "," ws asset-field ws "}"
direction-field ::= "\"direction\"" ws ":" ws ("\"income\"" | "\"expense\"" | "null")
amount-field ::= "\"amount\"" ws ":" ws (number | "null")
currency-field ::= "\"currency\"" ws ":" ws (string | "null")
category-field ::= "\"category\"" ws ":" ws record-category
record-category ::= {record_categories} | "null"
merchant-field ::= "\"merchant\"" ws ":" ws (string | "null")
time-field ::= "\"time_text\"" ws ":" ws (string | "null")
note-field ::= "\"note\"" ws ":" ws (string | "null")
cycle-field ::= "\"subscription_cycle\"" ws ":" ws ("\"monthly\"" | "\"yearly\"" | "null")
asset-field ::= "\"asset_info\"" ws ":" ws (asset | "null")
asset ::= "{" ws "\"name\"" ws ":" ws string "," ws "\"category\"" ws ":" ws asset-category "," ws "\"amount\"" ws ":" ws number "," ws "\"currency\"" ws ":" ws (string | "null") "," ws "\"recorded_on\"" ws ":" ws (string | "null") "," ws "\"note\"" ws ":" ws (string | "null") ws "}"
asset-category ::= {asset_categories}
string ::= "\"" char* "\""
char ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4})
number ::= "-"? ("0" | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [+-]? [0-9]+)?
ws ::= [ \t\n\r]*
"#;

pub fn record_json_grammar() -> String {
    RECORD_JSON_GRAMMAR_TEMPLATE
        .replace(
            "{record_categories}",
            &gbnf_json_string_alternatives(ALL_RECORD_CATEGORIES),
        )
        .replace(
            "{asset_categories}",
            &gbnf_json_string_alternatives(ASSET_CATEGORIES),
        )
}

fn gbnf_json_string_alternatives(values: &[&str]) -> String {
    values
        .iter()
        .map(|value| {
            let json_string = serde_json::to_string(value)
                .expect("fixed category must serialize as a JSON string");
            serde_json::to_string(&json_string)
                .expect("serialized fixed category must serialize as a GBNF literal")
        })
        .collect::<Vec<_>>()
        .join(" | ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU8, AtomicUsize, Ordering};
    use std::sync::{Mutex, MutexGuard};

    static CALLBACK_LOCK: Mutex<()> = Mutex::new(());
    static RESPONSE_MODE: AtomicU8 = AtomicU8::new(0);
    static FREE_COUNT: AtomicUsize = AtomicUsize::new(0);

    fn callback_lock() -> MutexGuard<'static, ()> {
        CALLBACK_LOCK
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn request() -> LocalLlmRequest {
        LocalLlmRequest {
            schema_version: 1,
            model_id: "test-model".to_string(),
            system_prompt: "system".to_string(),
            user_text: "user".to_string(),
            grammar: "root ::= []".to_string(),
            context_tokens: 8192,
            max_output_tokens: 2048,
            deadline_ms: 45_000,
        }
    }

    #[test]
    fn record_grammar_excludes_raw_json_control_characters() {
        let grammar = record_json_grammar();
        assert!(grammar.contains(r#"[^"\\\x7F\x00-\x1F]"#));
        assert!(!grammar.contains(r#"char ::= [^"\\] |"#));
    }

    #[test]
    fn record_grammar_constrains_categories_to_database_contract() {
        let grammar = record_json_grammar();

        for category in ALL_RECORD_CATEGORIES {
            let literal = gbnf_json_string_alternatives(&[category]);
            assert!(
                grammar.contains(&literal),
                "missing record category {category}"
            );
        }
        for category in ASSET_CATEGORIES {
            let literal = gbnf_json_string_alternatives(&[category]);
            assert!(
                grammar.contains(&literal),
                "missing asset category {category}"
            );
        }
        assert!(!grammar.contains(
            r#"category-field ::= \"\\\"category\\\"\" ws \":\" ws (string | \"null\")"#
        ));
        assert!(!grammar.contains("服饰"));
        assert!(!grammar.contains("运动户外"));
    }

    unsafe extern "C" fn test_run(_request: *const c_char) -> *mut c_char {
        match RESPONSE_MODE.load(Ordering::SeqCst) {
            0 => std::ptr::null_mut(),
            1 => CString::new(
                r#"{"status":"success","schema_version":1,"model_id":"test-model","content":"[]","elapsed_ms":12}"#,
            )
            .unwrap()
            .into_raw(),
            2 => CString::from_vec_with_nul(vec![0xff, 0])
                .unwrap()
                .into_raw(),
            3 => CString::new("not-json").unwrap().into_raw(),
            4 => CString::new(
                r#"{"status":"success","schema_version":2,"model_id":"test-model","content":"[]","elapsed_ms":12}"#,
            )
            .unwrap()
            .into_raw(),
            5 => CString::new(
                r#"{"status":"error","schema_version":1,"code":"cancelled","message":"cancelled by user"}"#,
            )
            .unwrap()
            .into_raw(),
            _ => unreachable!("unsupported response mode"),
        }
    }

    unsafe extern "C" fn test_cancel() {}

    unsafe extern "C" fn test_unload() {}

    unsafe extern "C" fn test_free(pointer: *mut c_char) {
        if !pointer.is_null() {
            drop(unsafe { CString::from_raw(pointer) });
            FREE_COUNT.fetch_add(1, Ordering::SeqCst);
        }
    }

    fn backend() -> LocalLlmBackend {
        LocalLlmBackend {
            run: test_run,
            cancel: test_cancel,
            unload: test_unload,
            free_string: test_free,
        }
    }

    #[tokio::test]
    async fn unregistered_backend_fails_explicitly() {
        let error = run(request()).await.unwrap_err();
        assert_eq!(error.code, LocalLlmErrorCode::BackendUnavailable);
    }

    #[test]
    fn null_response_is_rejected_without_freeing() {
        let _guard = callback_lock();
        RESPONSE_MODE.store(0, Ordering::SeqCst);
        FREE_COUNT.store(0, Ordering::SeqCst);
        let error = run_blocking(backend(), request()).unwrap_err();
        assert_eq!(error.code, LocalLlmErrorCode::InvalidRuntimeResponse);
        assert_eq!(FREE_COUNT.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn response_pointer_is_freed_on_success_and_decode_errors() {
        let _guard = callback_lock();
        for mode in [1_u8, 2, 3, 4, 5] {
            RESPONSE_MODE.store(mode, Ordering::SeqCst);
            FREE_COUNT.store(0, Ordering::SeqCst);
            let result = run_blocking(backend(), request());
            match mode {
                1 => assert_eq!(
                    result.unwrap(),
                    ("[]".to_string(), "test-model".to_string(), 12)
                ),
                5 => assert_eq!(result.unwrap_err().code, LocalLlmErrorCode::Cancelled),
                _ => assert_eq!(
                    result.unwrap_err().code,
                    LocalLlmErrorCode::InvalidRuntimeResponse
                ),
            }
            assert_eq!(FREE_COUNT.load(Ordering::SeqCst), 1, "mode={mode}");
        }
    }

    #[test]
    fn response_allocation_contract_survives_stress() {
        let _guard = callback_lock();
        RESPONSE_MODE.store(1, Ordering::SeqCst);
        FREE_COUNT.store(0, Ordering::SeqCst);
        for _ in 0..1_000 {
            run_blocking(backend(), request()).unwrap();
        }
        assert_eq!(FREE_COUNT.load(Ordering::SeqCst), 1_000);
    }

    #[test]
    fn cloud_fallback_matrix_is_exhaustive() {
        let allowed = [
            LocalLlmErrorCode::ModelNotInstalled,
            LocalLlmErrorCode::LoadFailed,
            LocalLlmErrorCode::OutOfMemory,
            LocalLlmErrorCode::InferenceFailed,
            LocalLlmErrorCode::Timeout,
            LocalLlmErrorCode::InvalidRuntimeResponse,
            LocalLlmErrorCode::UnsupportedChatTemplate,
        ];
        let rejected = [
            LocalLlmErrorCode::BackendUnavailable,
            LocalLlmErrorCode::Disabled,
            LocalLlmErrorCode::ModelBusy,
            LocalLlmErrorCode::InvalidRuntimeRequest,
            LocalLlmErrorCode::Cancelled,
            LocalLlmErrorCode::AppBackgrounded,
            LocalLlmErrorCode::MemoryPressure,
        ];
        assert!(
            allowed
                .into_iter()
                .all(LocalLlmErrorCode::allows_cloud_fallback)
        );
        assert!(
            rejected
                .into_iter()
                .all(|code| !code.allows_cloud_fallback())
        );
    }
}
