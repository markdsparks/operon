//! Portable cognitive runtime for constrained language models.
//!
//! `operon-core` owns orchestration, not inference. Applications provide an
//! [`InferenceProvider`] and optionally a [`GroundingProvider`]. The runtime
//! plans, retrieves, generates, validates, and performs bounded repair.

mod context;
mod error;
mod ffi;
mod models;
mod protocol;
mod runtime;
#[cfg(target_arch = "wasm32")]
mod wasm;

pub use context::{CompiledContext, ContextBudget, compile_context};
pub use error::{OperonError, OperonResult};
pub use models::{
    ArtifactReference, Clarification, CompletionContract, ExecutionPolicy, ExecutionTrace,
    GenerationRequest, GenerationResponse, GroundingProvider, InferenceProvider, MemoryAuthority,
    MemoryKind, MemoryRecord, MemoryScope, MemorySensitivity, MemoryStatus, Message,
    ModelCapabilities, OperonResponse, Plan, PrivacyClass, SessionArtifact, SkillCall,
    SkillDescriptor, SkillReceipt, SkillResult, Source, Stage, Strategy, TraceEvent,
};
pub use protocol::{
    EXECUTION_PROTOCOL_VERSION, EXECUTION_SNAPSHOT_VERSION, ExecutionCommand, ExecutionEvent,
    ExecutionResult, ExecutionSession, ExecutionSnapshot, ExecutionStep, HostFailureKind,
    SessionConfig, SkillPreparation,
};
pub use runtime::OperonRuntime;
