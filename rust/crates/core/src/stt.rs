use anyhow::{Result, anyhow, bail};
use chrono::{DateTime, Utc};
use serde::Serialize;
use std::ffi::{CStr, c_char};
use std::sync::{Mutex, OnceLock};
use uuid::Uuid;

pub type SttStartFn = unsafe extern "C" fn() -> i32;
pub type SttStopFn = unsafe extern "C" fn() -> *mut c_char;
pub type SttCancelFn = unsafe extern "C" fn();
pub type SttFreeStringFn = unsafe extern "C" fn(*mut c_char);

#[derive(Clone, Copy)]
pub struct SttBackend {
    pub start: SttStartFn,
    pub stop: SttStopFn,
    pub cancel: SttCancelFn,
    pub free_string: SttFreeStringFn,
}

unsafe impl Send for SttBackend {}
unsafe impl Sync for SttBackend {}

static STT_BACKEND: OnceLock<SttBackend> = OnceLock::new();
static STT_SESSION: OnceLock<Mutex<Option<SttSession>>> = OnceLock::new();

fn session_slot() -> &'static Mutex<Option<SttSession>> {
    STT_SESSION.get_or_init(|| Mutex::new(None))
}

#[derive(Debug, Clone, Serialize)]
pub struct SttSession {
    pub session_id: Uuid,
    pub started_at: DateTime<Utc>,
    pub profile_id: String,
}

pub fn register(backend: SttBackend) {
    let _ = STT_BACKEND.set(backend);
}

fn backend() -> Result<&'static SttBackend> {
    STT_BACKEND
        .get()
        .ok_or_else(|| anyhow!("stt backend not registered"))
}

pub fn start(profile_id: &str) -> Result<Uuid> {
    let backend = backend()?;
    let mut guard = session_slot()
        .lock()
        .map_err(|_| anyhow!("stt session mutex poisoned"))?;
    if guard.is_some() {
        bail!("stt session already in progress");
    }
    let code = unsafe { (backend.start)() };
    if code != 0 {
        bail!("swift stt start failed (code {code})");
    }
    let session = SttSession {
        session_id: Uuid::new_v4(),
        started_at: Utc::now(),
        profile_id: profile_id.to_string(),
    };
    let session_id = session.session_id;
    *guard = Some(session);
    Ok(session_id)
}

pub fn stop(profile_id: &str) -> Result<(Uuid, String)> {
    let backend = backend()?;
    let mut guard = session_slot()
        .lock()
        .map_err(|_| anyhow!("stt session mutex poisoned"))?;
    let session = guard
        .take()
        .ok_or_else(|| anyhow!("no active stt session"))?;
    if session.profile_id != profile_id {
        // Restore session and reject
        let session_id = session.session_id;
        *guard = Some(session);
        bail!("stt session profile mismatch (active={session_id})");
    }
    drop(guard);

    let raw = unsafe { (backend.stop)() };
    if raw.is_null() {
        bail!("语音识别停止失败");
    }
    let transcript = unsafe { CStr::from_ptr(raw) }
        .to_string_lossy()
        .into_owned();
    unsafe { (backend.free_string)(raw) };
    if transcript.is_empty() {
        bail!("未识别到语音内容，请重试。");
    }
    Ok((session.session_id, transcript))
}

pub fn cancel(profile_id: &str) -> Result<()> {
    let backend = backend()?;
    let mut guard = session_slot()
        .lock()
        .map_err(|_| anyhow!("stt session mutex poisoned"))?;
    if let Some(session) = guard.as_ref() {
        if session.profile_id != profile_id {
            bail!("stt session profile mismatch");
        }
    }
    *guard = None;
    unsafe { (backend.cancel)() };
    Ok(())
}

pub fn current_session() -> Option<SttSession> {
    session_slot().lock().ok().and_then(|g| g.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::sync::atomic::{AtomicI32, Ordering};

    static START_CALLS: AtomicI32 = AtomicI32::new(0);
    static STOP_CALLS: AtomicI32 = AtomicI32::new(0);

    extern "C" fn mock_start() -> i32 {
        START_CALLS.fetch_add(1, Ordering::SeqCst);
        0
    }
    extern "C" fn mock_stop() -> *mut c_char {
        STOP_CALLS.fetch_add(1, Ordering::SeqCst);
        CString::new("hello world").unwrap().into_raw()
    }
    extern "C" fn mock_cancel() {}
    extern "C" fn mock_free(ptr: *mut c_char) {
        if !ptr.is_null() {
            unsafe { drop(CString::from_raw(ptr)) };
        }
    }

    #[test]
    fn start_stop_roundtrip() {
        register(SttBackend {
            start: mock_start,
            stop: mock_stop,
            cancel: mock_cancel,
            free_string: mock_free,
        });
        let id = start("p1").expect("start ok");
        assert!(current_session().is_some());
        let (sid, text) = stop("p1").expect("stop ok");
        assert_eq!(sid, id);
        assert_eq!(text, "hello world");
        assert!(current_session().is_none());
    }
}
