use anyhow::{Context, Result, anyhow};
use billlens_apple_core::stt::{
    self, SttBackend, SttCancelFn, SttFreeStringFn, SttStartFn, SttStopFn,
};
use billlens_apple_core::{
    AppService, AssetUpdateInput, DraftInput, EngineBootstrap, EntrySource, LlmConfig,
    SubscriptionUpdate,
};
use billlens_apple_db::BillRepository;
use chrono::{DateTime, FixedOffset};
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use std::ffi::{CStr, CString, c_char};
use std::path::PathBuf;
use std::sync::OnceLock;
use tokio::runtime::Runtime;
use uuid::Uuid;

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static APP: OnceLock<RwLock<Option<AppService>>> = OnceLock::new();

#[derive(Debug, Serialize)]
struct Envelope<T> {
    ok: bool,
    data: Option<T>,
    error: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
enum EngineRequest {
    Bootstrap {
        database_path: String,
        profile_id: String,
        device_id: String,
        llm: Option<LlmConfig>,
        log_file_path: Option<String>,
    },
    Home {
        profile_id: String,
    },
    SubmitText {
        profile_id: String,
        content: String,
        auto_confirm: bool,
        source: Option<EntrySource>,
    },
    SaveDraft {
        profile_id: String,
        draft_id: String,
        draft: DraftInput,
    },
    ConfirmDraft {
        profile_id: String,
        draft_id: String,
    },
    DiscardDraft {
        profile_id: String,
        draft_id: String,
    },
    Ledger {
        profile_id: String,
        preset: String,
        start_at: Option<DateTime<FixedOffset>>,
        end_at: Option<DateTime<FixedOffset>>,
    },
    SttStart {
        profile_id: String,
    },
    SttStop {
        profile_id: String,
    },
    SttCancel {
        profile_id: String,
    },
    ConfirmAllDrafts {
        profile_id: String,
    },
    DeleteRecord {
        profile_id: String,
        record_id: String,
    },
    ListSubscriptions {
        profile_id: String,
    },
    UpdateSubscription {
        profile_id: String,
        subscription_id: String,
        update: SubscriptionUpdate,
    },
    PauseSubscription {
        profile_id: String,
        subscription_id: String,
    },
    ResumeSubscription {
        profile_id: String,
        subscription_id: String,
    },
    DeleteSubscription {
        profile_id: String,
        subscription_id: String,
    },
    ListCategories,
    ListAssets {
        profile_id: String,
    },
    UpdateAsset {
        profile_id: String,
        asset_id: String,
        update: AssetUpdateInput,
    },
    DeleteAsset {
        profile_id: String,
        asset_id: String,
    },
    DeleteAssetSnapshot {
        profile_id: String,
        snapshot_id: String,
    },
}

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| Runtime::new().expect("failed to create tokio runtime"))
}

fn app_slot() -> &'static RwLock<Option<AppService>> {
    APP.get_or_init(|| RwLock::new(None))
}

fn with_app<T>(f: impl FnOnce(&AppService) -> Result<T>) -> Result<T> {
    let guard = app_slot().read();
    let app = guard
        .as_ref()
        .ok_or_else(|| anyhow!("engine is not bootstrapped"))?;
    f(app)
}

fn encode_ok<T: Serialize>(data: T) -> *mut c_char {
    encode_envelope(Envelope {
        ok: true,
        data: Some(data),
        error: None,
    })
}

fn encode_error(message: String) -> *mut c_char {
    encode_envelope::<serde_json::Value>(Envelope {
        ok: false,
        data: None,
        error: Some(message),
    })
}

fn encode_envelope<T: Serialize>(payload: Envelope<T>) -> *mut c_char {
    let json = serde_json::to_string(&payload).unwrap_or_else(|error| {
        format!(r#"{{"ok":false,"data":null,"error":"failed to encode response: {error}"}}"#)
    });
    CString::new(json).unwrap().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn billlens_handle_request(request_json: *const c_char) -> *mut c_char {
    let response =
        handle_request_inner(request_json).unwrap_or_else(|error| encode_error(error.to_string()));
    response
}

/// SAFETY: All FFI entry points use `runtime().block_on()` to bridge async→sync.
/// This is safe because:
/// 1. The Tokio runtime is created with `rt-multi-thread` (see workspace Cargo.toml).
/// 2. Swift calls FFI via `Task.detached` on `.userInitiated`, never from inside
///    another `block_on` call.
/// Do NOT call `block_on` from within an already-running Tokio task — that will deadlock.
fn handle_request_inner(request_json: *const c_char) -> Result<*mut c_char> {
    if request_json.is_null() {
        return Ok(encode_error("request_json must not be null".to_string()));
    }

    let request_str = unsafe { CStr::from_ptr(request_json) }
        .to_str()
        .context("request_json is not valid utf-8")?;
    let request: EngineRequest =
        serde_json::from_str(request_str).context("failed to decode engine request")?;

    match request {
        EngineRequest::Bootstrap {
            database_path,
            profile_id,
            device_id,
            llm,
            log_file_path,
        } => {
            let db_path = PathBuf::from(database_path);
            let repo = runtime().block_on(BillRepository::connect(&db_path))?;
            let app = AppService::new(
                repo,
                EngineBootstrap {
                    device_id,
                    llm,
                    log_file_path,
                },
            )?;
            runtime().block_on(app.bootstrap(&profile_id))?;
            let mut slot = app_slot().write();
            *slot = Some(app.clone());
            Ok(encode_ok(serde_json::json!({ "profile_id": profile_id })))
        }
        EngineRequest::Home { profile_id } => with_app(|app| {
            let snapshot = runtime().block_on(app.home(&profile_id))?;
            Ok(encode_ok(snapshot))
        }),
        EngineRequest::SubmitText {
            profile_id,
            content,
            auto_confirm,
            source,
        } => with_app(|app| {
            let result = runtime().block_on(app.submit_text(
                &profile_id,
                content,
                auto_confirm,
                source.unwrap_or(EntrySource::Text),
            ))?;
            Ok(encode_ok(result))
        }),
        EngineRequest::SaveDraft {
            profile_id,
            draft_id,
            draft,
        } => {
            let draft_id = Uuid::parse_str(&draft_id).context("invalid draft_id")?;
            with_app(|app| {
                let result = runtime().block_on(app.save_draft(&profile_id, draft_id, draft))?;
                Ok(encode_ok(result))
            })
        }
        EngineRequest::ConfirmDraft {
            profile_id,
            draft_id,
        } => {
            let draft_id = Uuid::parse_str(&draft_id).context("invalid draft_id")?;
            with_app(|app| {
                let result = runtime().block_on(app.confirm_draft(&profile_id, draft_id))?;
                Ok(encode_ok(result))
            })
        }
        EngineRequest::DiscardDraft {
            profile_id,
            draft_id,
        } => {
            let draft_id = Uuid::parse_str(&draft_id).context("invalid draft_id")?;
            with_app(|app| {
                let result = runtime().block_on(app.discard_draft(&profile_id, draft_id))?;
                Ok(encode_ok(result))
            })
        }
        EngineRequest::Ledger {
            profile_id,
            preset,
            start_at,
            end_at,
        } => with_app(|app| {
            let result = runtime().block_on(app.ledger(&profile_id, &preset, start_at, end_at))?;
            Ok(encode_ok(result))
        }),
        EngineRequest::SttStart { profile_id } => {
            let session_id = stt::start(&profile_id)?;
            Ok(encode_ok(serde_json::json!({
                "session_id": session_id.to_string(),
            })))
        }
        EngineRequest::SttStop { profile_id } => {
            let (session_id, transcript) = stt::stop(&profile_id)?;
            Ok(encode_ok(serde_json::json!({
                "session_id": session_id.to_string(),
                "transcript": transcript,
            })))
        }
        EngineRequest::SttCancel { profile_id } => {
            stt::cancel(&profile_id)?;
            Ok(encode_ok(serde_json::json!({})))
        }
        EngineRequest::ConfirmAllDrafts { profile_id } => with_app(|app| {
            let result = runtime().block_on(app.confirm_all_drafts(&profile_id))?;
            Ok(encode_ok(result))
        }),
        EngineRequest::DeleteRecord {
            profile_id,
            record_id,
        } => {
            let record_id = Uuid::parse_str(&record_id).context("invalid record_id")?;
            with_app(|app| {
                runtime().block_on(app.delete_record(&profile_id, record_id))?;
                Ok(encode_ok(serde_json::json!({})))
            })
        }
        EngineRequest::ListSubscriptions { profile_id } => with_app(|app| {
            let subs = runtime().block_on(app.list_subscriptions(&profile_id))?;
            Ok(encode_ok(serde_json::json!({ "subscriptions": subs })))
        }),
        EngineRequest::UpdateSubscription {
            profile_id,
            subscription_id,
            update,
        } => {
            let sub_id = Uuid::parse_str(&subscription_id).context("invalid subscription_id")?;
            with_app(|app| {
                let sub =
                    runtime().block_on(app.update_subscription(&profile_id, sub_id, update))?;
                Ok(encode_ok(sub))
            })
        }
        EngineRequest::PauseSubscription {
            profile_id,
            subscription_id,
        } => {
            let sub_id = Uuid::parse_str(&subscription_id).context("invalid subscription_id")?;
            with_app(|app| {
                let sub = runtime().block_on(app.pause_subscription(&profile_id, sub_id))?;
                Ok(encode_ok(sub))
            })
        }
        EngineRequest::ResumeSubscription {
            profile_id,
            subscription_id,
        } => {
            let sub_id = Uuid::parse_str(&subscription_id).context("invalid subscription_id")?;
            with_app(|app| {
                let sub = runtime().block_on(app.resume_subscription(&profile_id, sub_id))?;
                Ok(encode_ok(sub))
            })
        }
        EngineRequest::DeleteSubscription {
            profile_id,
            subscription_id,
        } => {
            let sub_id = Uuid::parse_str(&subscription_id).context("invalid subscription_id")?;
            with_app(|app| {
                runtime().block_on(app.delete_subscription(&profile_id, sub_id))?;
                Ok(encode_ok(serde_json::json!({})))
            })
        }
        EngineRequest::ListCategories => Ok(encode_ok(serde_json::json!({
            "expense": billlens_apple_core::EXPENSE_CATEGORIES.to_vec(),
            "income": billlens_apple_core::INCOME_CATEGORIES.to_vec(),
        }))),
        EngineRequest::ListAssets { profile_id } => with_app(|app| {
            let assets = runtime().block_on(app.list_assets(&profile_id))?;
            Ok(encode_ok(serde_json::json!({ "assets": assets })))
        }),
        EngineRequest::UpdateAsset {
            profile_id,
            asset_id,
            update,
        } => {
            let asset_id = Uuid::parse_str(&asset_id).context("invalid asset_id")?;
            with_app(|app| {
                let asset = runtime().block_on(app.update_asset(&profile_id, asset_id, update))?;
                Ok(encode_ok(asset))
            })
        }
        EngineRequest::DeleteAsset {
            profile_id,
            asset_id,
        } => {
            let asset_id = Uuid::parse_str(&asset_id).context("invalid asset_id")?;
            with_app(|app| {
                runtime().block_on(app.delete_asset(&profile_id, asset_id))?;
                Ok(encode_ok(serde_json::json!({})))
            })
        }
        EngineRequest::DeleteAssetSnapshot {
            profile_id,
            snapshot_id,
        } => {
            let snapshot_id = Uuid::parse_str(&snapshot_id).context("invalid snapshot_id")?;
            with_app(|app| {
                runtime().block_on(app.delete_asset_snapshot(&profile_id, snapshot_id))?;
                Ok(encode_ok(serde_json::json!({})))
            })
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn billlens_register_stt_backend(
    start_fn: SttStartFn,
    stop_fn: SttStopFn,
    cancel_fn: SttCancelFn,
    free_fn: SttFreeStringFn,
) {
    stt::register(SttBackend {
        start: start_fn,
        stop: stop_fn,
        cancel: cancel_fn,
        free_string: free_fn,
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn billlens_free_string(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(value);
    }
}
