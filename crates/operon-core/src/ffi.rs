//! C-compatible handle API for the resumable command/event core.
//!
//! JSON keeps the ABI narrow and versioned while opaque handles keep Rust
//! session state private. Hosts own all side effects: they perform commands and
//! resume the handle with serialized events.

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;

use serde::Serialize;

use crate::{ExecutionEvent, ExecutionSession, ExecutionStep, SessionConfig};

pub const OPERON_FFI_OK: i32 = 0;
pub const OPERON_FFI_ERROR: i32 = 1;
pub const OPERON_FFI_INVALID_ARGUMENT: i32 = 2;

/// Opaque handle owned by the C caller until `operon_session_destroy`.
pub struct OperonSessionHandle {
    session: ExecutionSession,
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum FfiStep {
    Command { command: crate::ExecutionCommand },
    Complete { result: Box<crate::ExecutionResult> },
}

/// Returns the ABI version string owned by the library. Do not free this value.
#[unsafe(no_mangle)]
pub extern "C" fn operon_abi_version() -> *const c_char {
    c"0.2".as_ptr()
}

/// Creates an opaque execution-session handle.
///
/// `query` must be a valid, NUL-terminated UTF-8 string. `config_json` may be
/// null to use the default `SessionConfig`; otherwise it must be valid JSON.
/// On failure this returns null and writes an allocated error string to
/// `out_error` when non-null. Free allocated strings with `operon_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn operon_session_create(
    query: *const c_char,
    config_json: *const c_char,
    out_error: *mut *mut c_char,
) -> *mut OperonSessionHandle {
    unsafe { clear_out(out_error) };
    let result = catch_unwind(AssertUnwindSafe(|| {
        let query = unsafe { required_string(query, "query") }?;
        let config = if config_json.is_null() {
            SessionConfig::default()
        } else {
            let json = unsafe { required_string(config_json, "config_json") }?;
            serde_json::from_str(&json).map_err(|error| format!("invalid config_json: {error}"))?
        };
        ExecutionSession::new(query, config)
            .map(|session| Box::into_raw(Box::new(OperonSessionHandle { session })))
            .map_err(|error| error.to_string())
    }));
    match result {
        Ok(Ok(handle)) => handle,
        Ok(Err(error)) => {
            unsafe { write_error(out_error, error) };
            ptr::null_mut()
        }
        Err(_) => {
            unsafe { write_error(out_error, "Operon panicked while creating a session".into()) };
            ptr::null_mut()
        }
    }
}

/// Starts a session and serializes its next command or completed result.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn operon_session_start(
    handle: *mut OperonSessionHandle,
    out_step_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    unsafe { run_step(handle, out_step_json, out_error, |session| session.start()) }
}

/// Resumes a session with a serialized `ExecutionEvent` and returns its next
/// command or completed result.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn operon_session_resume(
    handle: *mut OperonSessionHandle,
    event_json: *const c_char,
    out_step_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    unsafe { clear_out(out_step_json) };
    unsafe { clear_out(out_error) };
    if out_step_json.is_null() {
        unsafe { write_error(out_error, "out_step_json cannot be null".into()) };
        return OPERON_FFI_INVALID_ARGUMENT;
    }
    if handle.is_null() {
        unsafe { write_error(out_error, "session handle cannot be null".into()) };
        return OPERON_FFI_INVALID_ARGUMENT;
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        let event_json = unsafe { required_string(event_json, "event_json") }?;
        let event: ExecutionEvent = serde_json::from_str(&event_json)
            .map_err(|error| format!("invalid event_json: {error}"))?;
        let session = unsafe { handle.as_mut() }.ok_or("session handle cannot be null")?;
        session
            .session
            .resume(event)
            .map_err(|error| error.to_string())
    }));
    unsafe { finish_step(result, out_step_json, out_error) }
}

/// Destroys a handle. It is safe to pass null. Do not reuse a destroyed handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn operon_session_destroy(handle: *mut OperonSessionHandle) {
    if !handle.is_null() {
        unsafe { drop(Box::from_raw(handle)) };
    }
}

/// Frees a string allocated by this library. It is safe to pass null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn operon_string_free(value: *mut c_char) {
    if !value.is_null() {
        unsafe { drop(CString::from_raw(value)) };
    }
}

unsafe fn run_step(
    handle: *mut OperonSessionHandle,
    out_step_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
    operation: impl FnOnce(&mut ExecutionSession) -> crate::OperonResult<ExecutionStep>,
) -> i32 {
    unsafe { clear_out(out_step_json) };
    unsafe { clear_out(out_error) };
    if out_step_json.is_null() {
        unsafe { write_error(out_error, "out_step_json cannot be null".into()) };
        return OPERON_FFI_INVALID_ARGUMENT;
    }
    if handle.is_null() {
        unsafe { write_error(out_error, "session handle cannot be null".into()) };
        return OPERON_FFI_INVALID_ARGUMENT;
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        let session = unsafe { &mut (*handle).session };
        operation(session).map_err(|error| error.to_string())
    }));
    unsafe { finish_step(result, out_step_json, out_error) }
}

unsafe fn finish_step(
    result: Result<Result<ExecutionStep, String>, Box<dyn std::any::Any + Send>>,
    out_step_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    match result {
        Ok(Ok(step)) => match serialize_step(step) {
            Ok(json) => {
                unsafe { write_out(out_step_json, json) };
                OPERON_FFI_OK
            }
            Err(error) => {
                unsafe { write_error(out_error, error) };
                OPERON_FFI_ERROR
            }
        },
        Ok(Err(error)) => {
            unsafe { write_error(out_error, error) };
            OPERON_FFI_ERROR
        }
        Err(_) => {
            unsafe {
                write_error(
                    out_error,
                    "Operon panicked while advancing a session".into(),
                )
            };
            OPERON_FFI_ERROR
        }
    }
}

fn serialize_step(step: ExecutionStep) -> Result<String, String> {
    let step = match step {
        ExecutionStep::Command(command) => FfiStep::Command { command },
        ExecutionStep::Complete(result) => FfiStep::Complete { result },
    };
    serde_json::to_string(&step).map_err(|error| format!("failed to serialize step: {error}"))
}

unsafe fn required_string(value: *const c_char, name: &str) -> Result<String, String> {
    if value.is_null() {
        return Err(format!("{name} cannot be null"));
    }
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| format!("{name} must be valid UTF-8"))
}

unsafe fn clear_out(out: *mut *mut c_char) {
    if !out.is_null() {
        unsafe { *out = ptr::null_mut() };
    }
}

unsafe fn write_out(out: *mut *mut c_char, value: String) {
    if !out.is_null() {
        let value = CString::new(value).expect("serialized JSON cannot contain NUL");
        unsafe { *out = value.into_raw() };
    }
}

unsafe fn write_error(out: *mut *mut c_char, value: String) {
    unsafe { write_out(out, value) };
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn ffi_starts_and_resumes_a_session() {
        let query = CString::new("What is two plus two?").unwrap();
        let config = CString::new(r#"{"policy":{"planning":"never"}}"#).unwrap();
        let mut error = ptr::null_mut();
        let handle = unsafe { operon_session_create(query.as_ptr(), config.as_ptr(), &mut error) };
        assert!(!handle.is_null());
        assert!(error.is_null());

        let mut step = ptr::null_mut();
        let status = unsafe { operon_session_start(handle, &mut step, &mut error) };
        assert_eq!(status, OPERON_FFI_OK);
        let step_json = unsafe { CStr::from_ptr(step) }.to_str().unwrap();
        assert!(step_json.contains("generate"));
        unsafe { operon_string_free(step) };

        let event = CString::new(
            r#"{"kind":"generation_completed","protocol_version":"0.2","request_id":1,"response":{"text":"{\"answer\":\"Four.\",\"confidence\":0.9,\"used_source_ids\":[]}","prompt_tokens":null,"completion_tokens":null,"finish_reason":null}}"#,
        )
        .unwrap();
        let status =
            unsafe { operon_session_resume(handle, event.as_ptr(), &mut step, &mut error) };
        assert_eq!(status, OPERON_FFI_OK);
        let result_json = unsafe { CStr::from_ptr(step) }.to_str().unwrap();
        assert!(result_json.contains("complete"));
        assert!(result_json.contains("Four."));
        unsafe { operon_string_free(step) };
        unsafe { operon_session_destroy(handle) };
    }
}
