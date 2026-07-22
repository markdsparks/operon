use web_time::Instant;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::OperonResult;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Strategy {
    Always,
    #[default]
    Adaptive,
    Never,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum PrivacyClass {
    #[default]
    Local,
    Remote,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ExecutionPolicy {
    pub local_only: bool,
    pub planning: Strategy,
    pub verification: Strategy,
    pub max_repair_attempts: usize,
    pub max_context_chars: usize,
    pub max_sources: usize,
    pub request_timeout_ms: u64,
}

impl Default for ExecutionPolicy {
    fn default() -> Self {
        Self {
            local_only: true,
            planning: Strategy::Adaptive,
            verification: Strategy::Adaptive,
            max_repair_attempts: 1,
            max_context_chars: 12_000,
            max_sources: 5,
            request_timeout_ms: 60_000,
        }
    }
}

impl ExecutionPolicy {
    pub(crate) fn validate(&self) -> OperonResult<()> {
        if self.max_context_chars == 0 {
            return Err(crate::OperonError::InvalidPolicy(
                "max_context_chars must be positive".into(),
            ));
        }
        if self.max_sources == 0 {
            return Err(crate::OperonError::InvalidPolicy(
                "max_sources must be positive".into(),
            ));
        }
        if self.request_timeout_ms == 0 {
            return Err(crate::OperonError::InvalidPolicy(
                "request_timeout_ms must be positive".into(),
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ModelCapabilities {
    pub structured_output: bool,
    pub tools: bool,
    pub vision: bool,
    pub streaming: bool,
    pub context_window: Option<usize>,
    pub privacy: PrivacyClass,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Message {
    pub role: String,
    pub content: String,
}

impl Message {
    pub fn system(content: impl Into<String>) -> Self {
        Self {
            role: "system".into(),
            content: content.into(),
        }
    }

    pub fn user(content: impl Into<String>) -> Self {
        Self {
            role: "user".into(),
            content: content.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GenerationRequest {
    pub messages: Vec<Message>,
    pub schema: Option<Value>,
    pub temperature: f32,
    pub max_tokens: Option<usize>,
    /// Provider-neutral reasoning budget (`none`, `low`, `medium`, or `high`).
    pub reasoning_effort: Option<String>,
    pub timeout_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenerationResponse {
    pub text: String,
    pub prompt_tokens: Option<usize>,
    pub completion_tokens: Option<usize>,
    pub finish_reason: Option<String>,
}

impl GenerationResponse {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            prompt_tokens: None,
            completion_tokens: None,
            finish_reason: None,
        }
    }
}

/// Adapter boundary for llama.cpp, MLX, ExecuTorch, system, or remote models.
pub trait InferenceProvider: Send + Sync {
    fn capabilities(&self) -> ModelCapabilities;
    fn generate(&self, request: &GenerationRequest) -> OperonResult<GenerationResponse>;
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Source {
    pub id: String,
    pub path: String,
    pub text: String,
    pub score: f32,
}

/// An application-declared capability that a model may request during planning.
///
/// Skills are descriptive contracts, not executable code. The host owns their
/// implementation, availability, permission prompt, timeout, and side effects.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SkillDescriptor {
    pub id: String,
    pub description: String,
    pub input_schema: Value,
    pub output_schema: Value,
    #[serde(default)]
    pub requires_user_confirmation: bool,
}

/// A typed skill request selected by the planning model from the host registry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SkillCall {
    pub skill_id: String,
    pub arguments: Value,
}

/// The host-owned result of a skill invocation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SkillResult {
    pub output: Value,
    #[serde(default)]
    pub sources: Vec<Source>,
}

/// Adapter boundary for lexical, vector, hybrid, or platform-native indexes.
pub trait GroundingProvider: Send + Sync {
    fn search(&self, query: &str, limit: usize) -> OperonResult<Vec<Source>>;
}

/// Typed records supplied by an application-owned durable-memory store.
///
/// The core never writes these records. Hosts enforce scope and retention before
/// returning them to a session through the command/event protocol.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryKind {
    Fact,
    Preference,
    Decision,
    Episode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryAuthority {
    ApplicationVerified,
    UserConfirmed,
    UserStated,
    ModelInferred,
    ImportedUntrusted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemorySensitivity {
    Private,
    Internal,
    Public,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryStatus {
    Active,
    Superseded,
    Tombstoned,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MemoryScope {
    pub namespace: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    pub allowed_sensitivities: Vec<MemorySensitivity>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MemoryRecord {
    pub id: String,
    pub namespace: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    pub kind: MemoryKind,
    pub content: String,
    pub authority: MemoryAuthority,
    pub sensitivity: MemorySensitivity,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f64>,
    #[serde(default)]
    pub source_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub occurred_at: Option<String>,
    pub observed_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub valid_from: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub valid_until: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub supersedes: Option<String>,
    pub status: MemoryStatus,
    pub created_by: String,
    pub schema_version: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Plan {
    pub intent: String,
    #[serde(default)]
    pub subquestions: Vec<String>,
    pub needs_grounding: bool,
    #[serde(default)]
    pub answer_requirements: Vec<String>,
    /// Optional calls selected from the session's declared skill registry.
    #[serde(default)]
    pub skill_calls: Vec<SkillCall>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Stage {
    Classify,
    Skill,
    Ground,
    Generate,
    Validate,
    Repair,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TraceEvent {
    pub stage: Stage,
    pub message: String,
    pub data: Value,
    pub elapsed_ms: f64,
}

#[derive(Debug)]
pub struct ExecutionTrace {
    started: Instant,
    pub events: Vec<TraceEvent>,
}

impl Default for ExecutionTrace {
    fn default() -> Self {
        Self {
            started: Instant::now(),
            events: Vec::new(),
        }
    }
}

impl ExecutionTrace {
    pub(crate) fn add(&mut self, stage: Stage, message: impl Into<String>, data: Value) {
        self.events.push(TraceEvent {
            stage,
            message: message.into(),
            data,
            elapsed_ms: self.started.elapsed().as_secs_f64() * 1_000.0,
        });
    }

    pub(crate) fn from_events(events: Vec<TraceEvent>) -> Self {
        Self {
            started: Instant::now(),
            events,
        }
    }
}

#[derive(Debug)]
pub struct OperonResponse {
    pub answer: String,
    pub output: Option<Value>,
    pub sources: Vec<Source>,
    pub confidence: f64,
    pub plan: Plan,
    pub trace: ExecutionTrace,
    pub declared_source_ids: Vec<String>,
    pub was_repaired: bool,
}
