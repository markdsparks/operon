//! Browser-facing bindings for the resumable execution protocol.
//!
//! This module intentionally exposes commands and events as JSON strings. The
//! JavaScript host owns inference, local data access, validation, cancellation,
//! and browser permissions; the Rust core owns only deterministic session state.

use serde::Serialize;
use wasm_bindgen::prelude::*;

use crate::{ExecutionEvent, ExecutionSession, ExecutionSnapshot, ExecutionStep, SessionConfig};

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum WasmStep {
    Command { command: crate::ExecutionCommand },
    Complete { result: crate::ExecutionResult },
}

/// A single resumable Operon execution session for browser hosts.
#[wasm_bindgen]
pub struct OperonWasmSession {
    session: ExecutionSession,
}

#[wasm_bindgen]
impl OperonWasmSession {
    /// `config_json` is an optional serialized `SessionConfig`.
    #[wasm_bindgen(constructor)]
    pub fn new(query: String, config_json: Option<String>) -> Result<OperonWasmSession, JsValue> {
        let config = match config_json {
            Some(json) => serde_json::from_str::<SessionConfig>(&json)
                .map_err(|error| JsValue::from_str(&format!("invalid config_json: {error}")))?,
            None => SessionConfig::default(),
        };
        let session = ExecutionSession::new(query, config)
            .map_err(|error| JsValue::from_str(&error.to_string()))?;
        Ok(Self { session })
    }

    /// Starts the session and returns a JSON `command` or `complete` step.
    pub fn start(&mut self) -> Result<String, JsValue> {
        serialize_step(self.session.start())
    }

    /// Applies a JSON `ExecutionEvent` and returns the next JSON step.
    pub fn resume(&mut self, event_json: String) -> Result<String, JsValue> {
        let event = serde_json::from_str::<ExecutionEvent>(&event_json)
            .map_err(|error| JsValue::from_str(&format!("invalid event_json: {error}")))?;
        serialize_step(self.session.resume(event))
    }

    /// Serializes deterministic execution state for app suspension or crash
    /// recovery. Treat the result as private application state.
    pub fn snapshot(&self) -> Result<String, JsValue> {
        serde_json::to_string(&self.session.snapshot())
            .map_err(|error| JsValue::from_str(&format!("could not serialize snapshot: {error}")))
    }

    /// Restores a previously snapshotted session without replaying completed
    /// actions.
    #[wasm_bindgen(js_name = fromSnapshot)]
    pub fn from_snapshot(snapshot_json: String) -> Result<OperonWasmSession, JsValue> {
        let snapshot = serde_json::from_str::<ExecutionSnapshot>(&snapshot_json)
            .map_err(|error| JsValue::from_str(&format!("invalid snapshot_json: {error}")))?;
        let session = ExecutionSession::restore(snapshot)
            .map_err(|error| JsValue::from_str(&error.to_string()))?;
        Ok(Self { session })
    }
}

/// Version owned by the Rust protocol, not by the JavaScript package.
#[wasm_bindgen]
pub fn execution_protocol_version() -> String {
    crate::EXECUTION_PROTOCOL_VERSION.to_owned()
}

fn serialize_step(step: crate::OperonResult<ExecutionStep>) -> Result<String, JsValue> {
    let step = step.map_err(|error| JsValue::from_str(&error.to_string()))?;
    let output = match step {
        ExecutionStep::Command(command) => WasmStep::Command { command },
        ExecutionStep::Complete(result) => WasmStep::Complete { result: *result },
    };
    serde_json::to_string(&output)
        .map_err(|error| JsValue::from_str(&format!("could not serialize execution step: {error}")))
}
