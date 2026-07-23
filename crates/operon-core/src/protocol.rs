use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::runtime::{
    ANSWER_SYSTEM_PROMPT, AnswerPayload, PLAN_SYSTEM_PROMPT, REPAIR_SYSTEM_PROMPT,
    REPLAN_SYSTEM_PROMPT, answer_schema, format_sources, is_complex, normalize_citations,
    normalize_confidence, output_instruction, parse_model_json, plan_schema, validate_answer,
    validate_output, validate_schema_definition, validate_schema_instance,
};
use crate::{
    ArtifactReference, Clarification, CompletionContract, ContextBudget, ExecutionPolicy,
    ExecutionTrace, GenerationRequest, GenerationResponse, MemoryRecord, MemoryScope, Message,
    OperonError, OperonResponse, OperonResult, Plan, SessionArtifact, SkillCall, SkillDescriptor,
    SkillReceipt, SkillResult, Source, Stage, Strategy, TraceEvent, compile_context,
};

pub const EXECUTION_PROTOCOL_VERSION: &str = "0.2";
pub const EXECUTION_SNAPSHOT_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ExecutionCommand {
    LoadSession {
        protocol_version: String,
        request_id: u64,
        session_id: String,
        limit: usize,
    },
    Generate {
        protocol_version: String,
        request_id: u64,
        stage: Stage,
        request: GenerationRequest,
    },
    Retrieve {
        protocol_version: String,
        request_id: u64,
        query: String,
        limit: usize,
    },
    SearchMemory {
        protocol_version: String,
        request_id: u64,
        query: String,
        scope: MemoryScope,
        limit: usize,
    },
    ValidateOutput {
        protocol_version: String,
        request_id: u64,
        output: Value,
    },
    /// Ask the application host to run one explicitly registered capability.
    /// The model never receives a direct side-effect channel.
    InvokeSkill {
        protocol_version: String,
        request_id: u64,
        /// Stable across snapshot/restore so hosts can safely deduplicate a
        /// side effect if delivery is retried.
        #[serde(default)]
        idempotency_key: String,
        skill_id: String,
        arguments: Value,
        requires_user_confirmation: bool,
    },
    /// Lets the host turn semantic references and partial model arguments into
    /// canonical, fully validated arguments before any capability is invoked.
    PrepareSkill {
        protocol_version: String,
        request_id: u64,
        skill_id: String,
        partial_arguments: Value,
        artifacts: Vec<ArtifactReference>,
    },
}

impl ExecutionCommand {
    pub fn request_id(&self) -> u64 {
        match self {
            Self::LoadSession { request_id, .. }
            | Self::Generate { request_id, .. }
            | Self::Retrieve { request_id, .. }
            | Self::SearchMemory { request_id, .. }
            | Self::ValidateOutput { request_id, .. }
            | Self::InvokeSkill { request_id, .. }
            | Self::PrepareSkill { request_id, .. } => *request_id,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostFailureKind {
    Provider,
    Grounding,
    Memory,
    Session,
    Skill,
    Cancelled,
    Timeout,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ExecutionEvent {
    SessionLoaded {
        protocol_version: String,
        request_id: u64,
        artifacts: Vec<SessionArtifact>,
    },
    GenerationCompleted {
        protocol_version: String,
        request_id: u64,
        response: GenerationResponse,
    },
    RetrievalCompleted {
        protocol_version: String,
        request_id: u64,
        sources: Vec<Source>,
    },
    MemorySearchCompleted {
        protocol_version: String,
        request_id: u64,
        records: Vec<MemoryRecord>,
    },
    OutputValidated {
        protocol_version: String,
        request_id: u64,
        errors: Vec<String>,
    },
    SkillCompleted {
        protocol_version: String,
        request_id: u64,
        result: SkillResult,
    },
    SkillPrepared {
        protocol_version: String,
        request_id: u64,
        outcome: SkillPreparation,
    },
    CommandFailed {
        protocol_version: String,
        request_id: u64,
        failure: HostFailureKind,
        message: String,
    },
}

impl ExecutionEvent {
    fn request_id(&self) -> u64 {
        match self {
            Self::SessionLoaded { request_id, .. }
            | Self::GenerationCompleted { request_id, .. }
            | Self::RetrievalCompleted { request_id, .. }
            | Self::MemorySearchCompleted { request_id, .. }
            | Self::OutputValidated { request_id, .. }
            | Self::SkillCompleted { request_id, .. }
            | Self::SkillPrepared { request_id, .. }
            | Self::CommandFailed { request_id, .. } => *request_id,
        }
    }

    fn protocol_version(&self) -> &str {
        match self {
            Self::SessionLoaded {
                protocol_version, ..
            }
            | Self::GenerationCompleted {
                protocol_version, ..
            }
            | Self::RetrievalCompleted {
                protocol_version, ..
            }
            | Self::MemorySearchCompleted {
                protocol_version, ..
            }
            | Self::OutputValidated {
                protocol_version, ..
            }
            | Self::SkillCompleted {
                protocol_version, ..
            }
            | Self::SkillPrepared {
                protocol_version, ..
            }
            | Self::CommandFailed {
                protocol_version, ..
            } => protocol_version,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExecutionResult {
    pub protocol_version: String,
    pub answer: String,
    pub output: Option<Value>,
    pub sources: Vec<Source>,
    pub confidence: f64,
    pub plan: Plan,
    pub trace: Vec<TraceEvent>,
    pub declared_source_ids: Vec<String>,
    pub was_repaired: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clarification: Option<Clarification>,
    /// Ordered, replay-safe evidence of every completed application action.
    #[serde(default)]
    pub skill_receipts: Vec<SkillReceipt>,
}

/// Host response for partial skill-call preparation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SkillPreparation {
    Ready { arguments: Value },
    NeedsInput { clarification: Clarification },
    Rejected { reason: String },
    Unavailable { reason: String },
}

impl ExecutionResult {
    pub(crate) fn into_response(self) -> OperonResponse {
        OperonResponse {
            answer: self.answer,
            output: self.output,
            sources: self.sources,
            confidence: self.confidence,
            plan: self.plan,
            trace: ExecutionTrace::from_events(self.trace),
            declared_source_ids: self.declared_source_ids,
            was_repaired: self.was_repaired,
            clarification: self.clarification,
        }
    }
}

#[derive(Debug)]
pub enum ExecutionStep {
    Command(ExecutionCommand),
    Complete(Box<ExecutionResult>),
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct SessionConfig {
    pub policy: ExecutionPolicy,
    pub has_grounding: bool,
    pub output_schema: Option<Value>,
    /// When true, the host must validate the application output before the
    /// session completes. Returned errors are eligible for targeted repair.
    pub has_application_validator: bool,
    /// An application-authorized durable-memory read scope. When present, the
    /// session yields SearchMemory before retrieval and generation.
    pub memory_scope: Option<MemoryScope>,
    /// Application-owned capabilities that the planner may request. An empty
    /// list means no capability invocation is possible.
    pub skills: Vec<SkillDescriptor>,
    /// Optional deterministic goal contract used by the internal task graph.
    /// When present, the session cannot silently finish before it is satisfied.
    pub completion: Option<CompletionContract>,
    /// When set, the session loads bounded typed artifacts before planning.
    pub session_id: Option<String>,
    pub max_session_artifacts: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
enum Pending {
    None,
    SessionLoad(u64),
    Plan(u64),
    Replan(u64),
    Retrieval(u64),
    MemorySearch(u64),
    Skill(u64),
    SkillPreparation(u64),
    Answer(u64),
    Repair(u64),
    ApplicationValidation(u64),
    Complete,
}

/// Versioned, serializable state for process suspension and crash recovery.
///
/// Snapshots may contain host-private artifact values and should be protected
/// like application state. A host restoring an outstanding command should
/// resume it with the same request ID; skill commands also carry a stable
/// idempotency key.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecutionSnapshot {
    pub snapshot_version: u32,
    pub protocol_version: String,
    query: String,
    config: SessionConfig,
    trace: Vec<TraceEvent>,
    pending: Pending,
    next_request_id: u64,
    plan: Option<Plan>,
    sources: Vec<Source>,
    memories: Vec<MemoryRecord>,
    artifacts: Vec<SessionArtifact>,
    skill_sources: Vec<Source>,
    completed_skill_ids: BTreeSet<String>,
    skill_receipts: Vec<SkillReceipt>,
    next_skill_index: usize,
    replan_attempts: usize,
    repair_attempts: usize,
    was_repaired: bool,
    pending_payload: Option<AnswerPayload>,
}

pub struct ExecutionSession {
    query: String,
    config: SessionConfig,
    trace: ExecutionTrace,
    pending: Pending,
    next_request_id: u64,
    plan: Option<Plan>,
    sources: Vec<Source>,
    memories: Vec<MemoryRecord>,
    artifacts: Vec<SessionArtifact>,
    skill_sources: Vec<Source>,
    completed_skill_ids: BTreeSet<String>,
    skill_receipts: Vec<SkillReceipt>,
    next_skill_index: usize,
    replan_attempts: usize,
    repair_attempts: usize,
    was_repaired: bool,
    pending_payload: Option<AnswerPayload>,
}

impl ExecutionSession {
    pub fn new(query: impl Into<String>, config: SessionConfig) -> OperonResult<Self> {
        let query = query.into();
        if query.trim().is_empty() {
            return Err(OperonError::InvalidRequest("query cannot be empty".into()));
        }
        config.policy.validate()?;
        if let Some(schema) = config.output_schema.as_ref() {
            let errors = validate_schema_definition(schema, "output_schema");
            if !errors.is_empty() {
                return Err(OperonError::InvalidPolicy(errors.join("; ")));
            }
        }
        let mut skill_ids = BTreeSet::new();
        for skill in &config.skills {
            if skill.id.trim().is_empty() {
                return Err(OperonError::InvalidPolicy(
                    "skill id cannot be empty".into(),
                ));
            }
            if !skill_ids.insert(skill.id.as_str()) {
                return Err(OperonError::InvalidPolicy(format!(
                    "duplicate skill id: {}",
                    skill.id
                )));
            }
            for (name, schema) in [
                ("input_schema", &skill.input_schema),
                ("output_schema", &skill.output_schema),
            ] {
                let errors =
                    validate_schema_definition(schema, &format!("skill {} {name}", skill.id));
                if !errors.is_empty() {
                    return Err(OperonError::InvalidPolicy(errors.join("; ")));
                }
            }
            if skill
                .consumes
                .iter()
                .chain(&skill.produces)
                .any(|kind| kind.trim().is_empty())
            {
                return Err(OperonError::InvalidPolicy(format!(
                    "skill {} artifact kinds cannot be empty",
                    skill.id
                )));
            }
        }
        if let Some(completion) = config.completion.as_ref() {
            for skill_id in &completion.required_skill_ids {
                if !skill_ids.contains(skill_id.as_str()) {
                    return Err(OperonError::InvalidPolicy(format!(
                        "completion contract references unknown skill: {skill_id}"
                    )));
                }
            }
            if completion
                .required_artifact_kinds
                .iter()
                .any(|kind| kind.trim().is_empty())
            {
                return Err(OperonError::InvalidPolicy(
                    "completion artifact kinds cannot be empty".into(),
                ));
            }
        }
        Ok(Self {
            query: query.trim().to_owned(),
            config,
            trace: ExecutionTrace::default(),
            pending: Pending::None,
            next_request_id: 1,
            plan: None,
            sources: Vec::new(),
            memories: Vec::new(),
            artifacts: Vec::new(),
            skill_sources: Vec::new(),
            completed_skill_ids: BTreeSet::new(),
            skill_receipts: Vec::new(),
            next_skill_index: 0,
            replan_attempts: 0,
            repair_attempts: 0,
            was_repaired: false,
            pending_payload: None,
        })
    }

    /// Captures the deterministic runtime state at the current command
    /// boundary. The host remains responsible for persisting any outstanding
    /// command alongside this snapshot.
    pub fn snapshot(&self) -> ExecutionSnapshot {
        ExecutionSnapshot {
            snapshot_version: EXECUTION_SNAPSHOT_VERSION,
            protocol_version: EXECUTION_PROTOCOL_VERSION.into(),
            query: self.query.clone(),
            config: self.config.clone(),
            trace: self.trace.events.clone(),
            pending: self.pending.clone(),
            next_request_id: self.next_request_id,
            plan: self.plan.clone(),
            sources: self.sources.clone(),
            memories: self.memories.clone(),
            artifacts: self.artifacts.clone(),
            skill_sources: self.skill_sources.clone(),
            completed_skill_ids: self.completed_skill_ids.clone(),
            skill_receipts: self.skill_receipts.clone(),
            next_skill_index: self.next_skill_index,
            replan_attempts: self.replan_attempts,
            repair_attempts: self.repair_attempts,
            was_repaired: self.was_repaired,
            pending_payload: self.pending_payload.clone(),
        }
    }

    /// Restores a session without re-running completed work.
    pub fn restore(snapshot: ExecutionSnapshot) -> OperonResult<Self> {
        if snapshot.snapshot_version != EXECUTION_SNAPSHOT_VERSION {
            return Err(OperonError::InvalidRequest(format!(
                "unsupported execution snapshot version: {}",
                snapshot.snapshot_version
            )));
        }
        if snapshot.protocol_version != EXECUTION_PROTOCOL_VERSION {
            return Err(OperonError::InvalidRequest(format!(
                "snapshot protocol {} does not match runtime protocol {}",
                snapshot.protocol_version, EXECUTION_PROTOCOL_VERSION
            )));
        }
        // Re-run normal admission checks so a tampered snapshot cannot bypass
        // policy, schema, or skill-registry validation.
        let _ = Self::new(snapshot.query.clone(), snapshot.config.clone())?;
        Ok(Self {
            query: snapshot.query,
            config: snapshot.config,
            trace: ExecutionTrace::from_events(snapshot.trace),
            pending: snapshot.pending,
            next_request_id: snapshot.next_request_id,
            plan: snapshot.plan,
            sources: snapshot.sources,
            memories: snapshot.memories,
            artifacts: snapshot.artifacts,
            skill_sources: snapshot.skill_sources,
            completed_skill_ids: snapshot.completed_skill_ids,
            skill_receipts: snapshot.skill_receipts,
            next_skill_index: snapshot.next_skill_index,
            replan_attempts: snapshot.replan_attempts,
            repair_attempts: snapshot.repair_attempts,
            was_repaired: snapshot.was_repaired,
            pending_payload: snapshot.pending_payload,
        })
    }

    pub fn start(&mut self) -> OperonResult<ExecutionStep> {
        if !matches!(self.pending, Pending::None) {
            return Err(OperonError::InvalidRequest(
                "execution session has already started".into(),
            ));
        }
        if let Some(session_id) = self.config.session_id.clone() {
            let request_id = self.allocate_request_id();
            self.pending = Pending::SessionLoad(request_id);
            return Ok(ExecutionStep::Command(ExecutionCommand::LoadSession {
                protocol_version: EXECUTION_PROTOCOL_VERSION.into(),
                request_id,
                session_id,
                limit: self.config.max_session_artifacts,
            }));
        }
        self.start_after_session()
    }

    fn start_after_session(&mut self) -> OperonResult<ExecutionStep> {
        let should_plan = self.config.policy.planning == Strategy::Always
            || (self.config.policy.planning == Strategy::Adaptive && is_complex(&self.query));
        if should_plan {
            return Ok(self.plan_command());
        }
        self.plan = Some(Plan {
            intent: self.query.clone(),
            subquestions: Vec::new(),
            needs_grounding: self.config.has_grounding,
            answer_requirements: Vec::new(),
            skill_calls: Vec::new(),
            clarification: None,
        });
        self.trace.add(
            Stage::Classify,
            "used fast-path plan",
            json!({ "complex": false }),
        );
        self.route_plan()
    }

    pub fn resume(&mut self, event: ExecutionEvent) -> OperonResult<ExecutionStep> {
        if event.protocol_version() != EXECUTION_PROTOCOL_VERSION {
            return Err(OperonError::InvalidRequest(format!(
                "unsupported execution protocol version: {}",
                event.protocol_version()
            )));
        }
        let expected = match self.pending {
            Pending::SessionLoad(id)
            | Pending::Plan(id)
            | Pending::Replan(id)
            | Pending::Retrieval(id)
            | Pending::MemorySearch(id)
            | Pending::Skill(id)
            | Pending::SkillPreparation(id)
            | Pending::Answer(id)
            | Pending::Repair(id)
            | Pending::ApplicationValidation(id) => id,
            Pending::None => {
                return Err(OperonError::InvalidRequest(
                    "execution session has not yielded a command".into(),
                ));
            }
            Pending::Complete => {
                return Err(OperonError::InvalidRequest(
                    "execution session is already complete".into(),
                ));
            }
        };
        if event.request_id() != expected {
            return Err(OperonError::InvalidRequest(format!(
                "event request ID {} does not match outstanding command {expected}",
                event.request_id()
            )));
        }
        if let ExecutionEvent::CommandFailed {
            failure, message, ..
        } = event
        {
            self.pending = Pending::Complete;
            return Err(match failure {
                HostFailureKind::Grounding => OperonError::Grounding(message),
                HostFailureKind::Memory | HostFailureKind::Session => OperonError::Memory(message),
                HostFailureKind::Skill => OperonError::Provider(message),
                HostFailureKind::Provider
                | HostFailureKind::Cancelled
                | HostFailureKind::Timeout => OperonError::Provider(message),
            });
        }

        match (&self.pending, event) {
            (Pending::SessionLoad(_), ExecutionEvent::SessionLoaded { artifacts, .. }) => {
                self.artifacts = artifacts;
                self.trace.add(Stage::Ground, "loaded bounded typed session artifacts", json!({ "artifacts": self.artifacts.len(), "kinds": self.artifacts.iter().map(|artifact| &artifact.kind).collect::<Vec<_>>() }));
                self.start_after_session()
            }
            (Pending::Plan(_), ExecutionEvent::GenerationCompleted { response, .. }) => {
                self.accept_plan(response)
            }
            (Pending::Replan(_), ExecutionEvent::GenerationCompleted { response, .. }) => {
                self.accept_replan(response)
            }
            (Pending::Retrieval(_), ExecutionEvent::RetrievalCompleted { sources, .. }) => {
                self.sources = self.skill_sources.clone();
                self.sources.extend(sources);
                self.normalize_source_ids();
                self.trace.add(
                    Stage::Ground,
                    "retrieved local context",
                    json!({
                        "sources": self.sources.len(),
                        "paths": self.sources.iter().map(|source| &source.path).collect::<Vec<_>>()
                    }),
                );
                Ok(self.answer_command())
            }
            (Pending::MemorySearch(_), ExecutionEvent::MemorySearchCompleted { records, .. }) => {
                self.memories = records;
                self.trace.add(
                    Stage::Ground,
                    "retrieved scoped durable memory",
                    json!({ "records": self.memories.len() }),
                );
                Ok(self.after_memory())
            }
            (Pending::Skill(_), ExecutionEvent::SkillCompleted { result, .. }) => {
                self.accept_skill_result(result)
            }
            (Pending::SkillPreparation(_), ExecutionEvent::SkillPrepared { outcome, .. }) => {
                self.accept_skill_preparation(outcome)
            }
            (Pending::Answer(_), ExecutionEvent::GenerationCompleted { response, .. }) => {
                self.trace_generation(Stage::Generate, &response);
                self.accept_answer(response)
            }
            (Pending::Repair(_), ExecutionEvent::GenerationCompleted { response, .. }) => {
                self.trace.add(
                    Stage::Repair,
                    "received targeted repair",
                    usage_data(&response),
                );
                self.accept_repair(response)
            }
            (Pending::ApplicationValidation(_), ExecutionEvent::OutputValidated { errors, .. }) => {
                self.accept_application_validation(errors)
            }
            _ => Err(OperonError::InvalidRequest(
                "event kind does not match outstanding command".into(),
            )),
        }
    }

    fn plan_command(&mut self) -> ExecutionStep {
        let ready_skill_ids = self.ready_skill_ids();
        let request_id = self.allocate_request_id();
        self.pending = Pending::Plan(request_id);
        ExecutionStep::Command(ExecutionCommand::Generate {
            protocol_version: EXECUTION_PROTOCOL_VERSION.into(),
            request_id,
            stage: Stage::Classify,
            request: GenerationRequest {
                messages: vec![
                    Message::system(PLAN_SYSTEM_PROMPT),
                    Message::user(format!(
                        "QUERY:\n{}\n\nTYPED SESSION ARTIFACTS (references only):\n{}\n\nCOMPLETION CONTRACT:\n{}\n\nREADY SKILLS:\n{}",
                        self.query,
                        self.artifact_catalog(),
                        serde_json::to_string_pretty(&self.config.completion)
                            .expect("completion contract serializes"),
                        self.skill_catalog_for(&ready_skill_ids)
                    )),
                ],
                schema: Some(plan_schema_for(&ready_skill_ids)),
                temperature: 0.0,
                max_tokens: Some(500),
                reasoning_effort: Some("none".into()),
                timeout_ms: self.config.policy.request_timeout_ms,
            },
        })
    }

    fn accept_plan(&mut self, response: GenerationResponse) -> OperonResult<ExecutionStep> {
        let mut plan: Plan = parse_model_json(&response.text)?;
        let model_requested_grounding = plan.needs_grounding;
        plan.intent = plan.intent.trim().to_owned();
        plan.subquestions.retain(|item| !item.trim().is_empty());
        plan.answer_requirements
            .retain(|item| !item.trim().is_empty());
        let requested_skill_calls = plan.skill_calls.len();
        plan.skill_calls
            .retain(|call| self.is_ready_skill_call(call));
        plan.needs_grounding = self.config.has_grounding;
        if plan.intent.is_empty() {
            return Err(OperonError::InvalidModelOutput(
                "plan intent must be a non-empty string".into(),
            ));
        }
        self.trace.add(
            Stage::Classify,
            "model produced task plan",
            json!({
                "subquestions": plan.subquestions.len(),
                "needs_grounding": plan.needs_grounding,
                "model_requested_grounding": model_requested_grounding,
                "prompt_tokens": response.prompt_tokens,
                "completion_tokens": response.completion_tokens,
                "finish_reason": response.finish_reason
                ,"requested_skill_calls": requested_skill_calls
                ,"accepted_skill_calls": plan.skill_calls.len()
            }),
        );
        self.plan = Some(plan);
        self.route_plan()
    }

    fn route_plan(&mut self) -> OperonResult<ExecutionStep> {
        if let Some(clarification) = self
            .plan
            .as_ref()
            .and_then(|plan| plan.clarification.clone())
        {
            return Ok(self.complete_clarification(clarification));
        }
        if self.config.completion.is_some() && self.completion_satisfied() {
            return Ok(self.after_plan_without_skills());
        }
        if let Some(command) = self.next_skill_command() {
            return Ok(command);
        }
        if self.has_unmet_completion_contract() {
            let ready = self.ready_skill_ids();
            return Ok(self.complete_clarification(Clarification {
                prompt: if ready.is_empty() {
                    "I cannot complete the requested action until its required context is available."
                        .into()
                } else {
                    "I need a little more information to choose the next valid action.".into()
                },
                missing_fields: self.missing_completion_requirements(),
                skill_id: None,
            }));
        }
        if self.config.policy.require_skill_or_clarification {
            return Ok(self.complete_clarification(Clarification {
                prompt: "I need a little more information before I can complete that action."
                    .into(),
                missing_fields: Vec::new(),
                skill_id: None,
            }));
        }
        if let Some(scope) = self.config.memory_scope.clone() {
            let request_id = self.allocate_request_id();
            self.pending = Pending::MemorySearch(request_id);
            return Ok(ExecutionStep::Command(ExecutionCommand::SearchMemory {
                protocol_version: EXECUTION_PROTOCOL_VERSION.into(),
                request_id,
                query: self.context_query(),
                scope,
                limit: self.config.policy.max_sources,
            }));
        }
        Ok(self.after_memory())
    }

    fn after_memory(&mut self) -> ExecutionStep {
        if self.config.has_grounding {
            let request_id = self.allocate_request_id();
            self.pending = Pending::Retrieval(request_id);
            ExecutionStep::Command(ExecutionCommand::Retrieve {
                protocol_version: EXECUTION_PROTOCOL_VERSION.into(),
                request_id,
                query: self.context_query(),
                limit: self.config.policy.max_sources,
            })
        } else {
            self.sources = self.skill_sources.clone();
            self.normalize_source_ids();
            self.trace.add(
                Stage::Ground,
                "grounding not required",
                json!({ "sources": self.sources.len() }),
            );
            self.answer_command()
        }
    }

    fn context_query(&self) -> String {
        let plan = self.plan.as_ref().expect("plan exists");
        std::iter::once(self.query.as_str())
            .chain(std::iter::once(plan.intent.as_str()))
            .chain(plan.subquestions.iter().map(String::as_str))
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn skill_catalog_for(&self, skill_ids: &BTreeSet<String>) -> String {
        let skills: Vec<&SkillDescriptor> = self
            .config
            .skills
            .iter()
            .filter(|skill| skill_ids.contains(&skill.id))
            .collect();
        if skills.is_empty() {
            return "(none)".into();
        }
        serde_json::to_string_pretty(&skills).expect("ready skill catalog serializes")
    }

    fn artifact_catalog(&self) -> String {
        if self.artifacts.is_empty() {
            return "(none)".into();
        }
        let references: Vec<ArtifactReference> =
            self.artifacts.iter().map(ArtifactReference::from).collect();
        serde_json::to_string_pretty(&references).expect("artifact references serialize")
    }

    fn is_known_skill_call(&self, call: &SkillCall) -> bool {
        self.config
            .skills
            .iter()
            .any(|skill| skill.id == call.skill_id)
    }

    fn is_ready_skill_call(&self, call: &SkillCall) -> bool {
        self.is_known_skill_call(call) && self.ready_skill_ids().contains(&call.skill_id)
    }

    fn available_artifact_kinds(&self) -> BTreeSet<String> {
        self.artifacts
            .iter()
            .map(|artifact| artifact.kind.clone())
            .collect()
    }

    /// Computes the graph slice that can contribute to the declared goal by
    /// walking backward from required skills and artifact kinds.
    fn relevant_skill_ids(&self) -> BTreeSet<String> {
        let Some(contract) = self.config.completion.as_ref() else {
            return self
                .config
                .skills
                .iter()
                .map(|skill| skill.id.clone())
                .collect();
        };
        let mut relevant: BTreeSet<String> = contract.required_skill_ids.iter().cloned().collect();
        let mut needed_kinds: BTreeSet<String> =
            contract.required_artifact_kinds.iter().cloned().collect();
        for skill in &self.config.skills {
            if relevant.contains(&skill.id) {
                needed_kinds.extend(skill.consumes.iter().cloned());
            }
        }
        loop {
            let before = relevant.len();
            for skill in &self.config.skills {
                if skill
                    .produces
                    .iter()
                    .any(|kind| needed_kinds.contains(kind))
                {
                    relevant.insert(skill.id.clone());
                    needed_kinds.extend(skill.consumes.iter().cloned());
                }
            }
            if relevant.len() == before {
                break;
            }
        }
        relevant
    }

    fn ready_skill_ids(&self) -> BTreeSet<String> {
        let available = self.available_artifact_kinds();
        let relevant = self.relevant_skill_ids();
        self.config
            .skills
            .iter()
            .filter(|skill| relevant.contains(&skill.id))
            .filter(|skill| !self.completed_skill_ids.contains(&skill.id))
            .filter(|skill| skill.consumes.iter().all(|kind| available.contains(kind)))
            .map(|skill| skill.id.clone())
            .collect()
    }

    fn completion_satisfied(&self) -> bool {
        let Some(contract) = self.config.completion.as_ref() else {
            return false;
        };
        let kinds = self.available_artifact_kinds();
        contract
            .required_skill_ids
            .iter()
            .all(|id| self.completed_skill_ids.contains(id))
            && contract
                .required_artifact_kinds
                .iter()
                .all(|kind| kinds.contains(kind))
    }

    fn has_unmet_completion_contract(&self) -> bool {
        self.config.completion.is_some() && !self.completion_satisfied()
    }

    fn missing_completion_requirements(&self) -> Vec<String> {
        let Some(contract) = self.config.completion.as_ref() else {
            return Vec::new();
        };
        let kinds = self.available_artifact_kinds();
        contract
            .required_skill_ids
            .iter()
            .filter(|id| !self.completed_skill_ids.contains(*id))
            .map(|id| format!("skill:{id}"))
            .chain(
                contract
                    .required_artifact_kinds
                    .iter()
                    .filter(|kind| !kinds.contains(*kind))
                    .map(|kind| format!("artifact:{kind}")),
            )
            .collect()
    }

    fn next_skill_command(&mut self) -> Option<ExecutionStep> {
        let call = self
            .plan
            .as_ref()?
            .skill_calls
            .get(self.next_skill_index)?
            .clone();
        let skill_exists = self
            .config
            .skills
            .iter()
            .find(|skill| skill.id == call.skill_id)
            .is_some()
            && self.ready_skill_ids().contains(&call.skill_id);
        if !skill_exists {
            return None;
        }
        let request_id = self.allocate_request_id();
        self.pending = Pending::SkillPreparation(request_id);
        Some(ExecutionStep::Command(ExecutionCommand::PrepareSkill {
            protocol_version: EXECUTION_PROTOCOL_VERSION.into(),
            request_id,
            skill_id: call.skill_id,
            partial_arguments: call.arguments,
            artifacts: self.artifacts.iter().map(ArtifactReference::from).collect(),
        }))
    }

    fn accept_skill_result(&mut self, result: SkillResult) -> OperonResult<ExecutionStep> {
        let invocation_request_id = match self.pending {
            Pending::Skill(request_id) => request_id,
            _ => {
                return Err(OperonError::InvalidRequest(
                    "skill completion has no pending invocation".into(),
                ));
            }
        };
        let call = self
            .plan
            .as_ref()
            .and_then(|plan| plan.skill_calls.get(self.next_skill_index))
            .ok_or_else(|| {
                OperonError::InvalidRequest("skill completion has no pending call".into())
            })?;
        let skill = self
            .config
            .skills
            .iter()
            .find(|skill| skill.id == call.skill_id)
            .ok_or_else(|| {
                OperonError::InvalidRequest(
                    "skill completion refers to an unavailable skill".into(),
                )
            })?;
        let errors = validate_schema_instance(&result.output, &skill.output_schema, "skill output");
        if !errors.is_empty() {
            return Err(OperonError::Validation(errors));
        }
        let published_kinds: BTreeSet<&str> = result
            .artifacts
            .iter()
            .map(|artifact| artifact.kind.as_str())
            .collect();
        let missing_promises: Vec<&str> = skill
            .produces
            .iter()
            .map(String::as_str)
            .filter(|kind| !published_kinds.contains(kind))
            .collect();
        if !missing_promises.is_empty() {
            return Err(OperonError::Validation(vec![format!(
                "skill {} did not publish promised artifact kinds: {}",
                skill.id,
                missing_promises.join(", ")
            )]));
        }
        let skill_id = skill.id.clone();
        let artifact_ids = result
            .artifacts
            .iter()
            .map(|artifact| artifact.id.clone())
            .collect();
        let artifact_kinds = result
            .artifacts
            .iter()
            .map(|artifact| artifact.kind.clone())
            .collect();
        let text = serde_json::to_string_pretty(&result.output)
            .map_err(|error| OperonError::InvalidModelOutput(error.to_string()))?;
        self.skill_sources.push(Source {
            id: format!("skill-{}", self.next_skill_index + 1),
            path: format!("skill://{}", skill_id),
            text,
            score: 1.0,
        });
        self.skill_sources.extend(result.sources);
        self.artifacts.extend(result.artifacts);
        self.completed_skill_ids.insert(skill_id.clone());
        self.skill_receipts.push(SkillReceipt {
            idempotency_key: format!("operon:skill:{skill_id}:request:{invocation_request_id}"),
            skill_id: skill_id.clone(),
            artifact_ids,
            artifact_kinds,
        });
        self.trace.add(
            Stage::Skill,
            "completed application-owned skill",
            json!({ "skill_id": skill_id, "sources": self.skill_sources.len(), "artifacts": self.artifacts.len(), "completion_satisfied": self.completion_satisfied() }),
        );
        self.next_skill_index = 0;
        if self.completion_satisfied() {
            return Ok(self.after_plan_without_skills());
        }
        let ready = self.ready_skill_ids();
        if ready.is_empty() {
            if self.has_unmet_completion_contract() {
                return Ok(self.complete_clarification(Clarification {
                    prompt: "I cannot complete the requested action until its required context is available.".into(),
                    missing_fields: self.missing_completion_requirements(),
                    skill_id: None,
                }));
            }
            if self.replan_attempts >= self.config.policy.max_replans {
                return Ok(self.after_plan_without_skills());
            }
        }
        if self.replan_attempts < self.config.policy.max_replans {
            self.replan_attempts += 1;
            return Ok(self.replan_command());
        }
        Ok(self.after_plan_without_skills())
    }

    fn accept_skill_preparation(
        &mut self,
        outcome: SkillPreparation,
    ) -> OperonResult<ExecutionStep> {
        let call = self
            .plan
            .as_ref()
            .and_then(|plan| plan.skill_calls.get(self.next_skill_index))
            .cloned()
            .ok_or_else(|| {
                OperonError::InvalidRequest("skill preparation has no pending call".into())
            })?;
        let skill = self
            .config
            .skills
            .iter()
            .find(|skill| skill.id == call.skill_id)
            .ok_or_else(|| {
                OperonError::InvalidRequest(
                    "skill preparation refers to an unavailable skill".into(),
                )
            })?;
        let skill_id = skill.id.clone();
        let requires_user_confirmation = skill.requires_user_confirmation;
        match outcome {
            SkillPreparation::Ready { arguments } => {
                let errors =
                    validate_schema_instance(&arguments, &skill.input_schema, "skill arguments");
                if !errors.is_empty() {
                    return Err(OperonError::Validation(errors));
                }
                let request_id = self.allocate_request_id();
                self.pending = Pending::Skill(request_id);
                Ok(ExecutionStep::Command(ExecutionCommand::InvokeSkill {
                    protocol_version: EXECUTION_PROTOCOL_VERSION.into(),
                    request_id,
                    idempotency_key: format!("operon:skill:{skill_id}:request:{request_id}"),
                    skill_id,
                    arguments,
                    requires_user_confirmation,
                }))
            }
            SkillPreparation::NeedsInput { clarification } => {
                Ok(self.complete_clarification(clarification))
            }
            SkillPreparation::Rejected { reason } | SkillPreparation::Unavailable { reason } => {
                Ok(self.complete_clarification(Clarification {
                    prompt: reason,
                    missing_fields: Vec::new(),
                    skill_id: Some(call.skill_id),
                }))
            }
        }
    }

    fn replan_command(&mut self) -> ExecutionStep {
        let ready_skill_ids = self.ready_skill_ids();
        let request_id = self.allocate_request_id();
        self.pending = Pending::Replan(request_id);
        ExecutionStep::Command(ExecutionCommand::Generate {
            protocol_version: EXECUTION_PROTOCOL_VERSION.into(),
            request_id,
            stage: Stage::Replan,
            request: GenerationRequest {
                messages: vec![
                    Message::system(REPLAN_SYSTEM_PROMPT),
                    Message::user(format!(
                        "QUERY:\n{}\n\nTYPED SESSION ARTIFACTS (references only):\n{}\n\nCOMPLETED SKILL RESULTS:\n{}\n\nCOMPLETION CONTRACT:\n{}\n\nREADY SKILLS (the only valid next actions):\n{}",
                        self.query,
                        self.artifact_catalog(),
                        format_sources(&self.skill_sources, self.config.policy.max_context_chars),
                        serde_json::to_string_pretty(&self.config.completion)
                            .expect("completion contract serializes"),
                        self.skill_catalog_for(&ready_skill_ids)
                    )),
                ],
                schema: Some(plan_schema_for(&ready_skill_ids)),
                temperature: 0.0,
                max_tokens: Some(500),
                reasoning_effort: Some("none".into()),
                timeout_ms: self.config.policy.request_timeout_ms,
            },
        })
    }

    fn accept_replan(&mut self, response: GenerationResponse) -> OperonResult<ExecutionStep> {
        let ready_skill_ids = self.ready_skill_ids();
        let next: Plan = parse_model_json(&response.text)?;
        if let Some(invalid) = next
            .skill_calls
            .iter()
            .find(|call| !ready_skill_ids.contains(&call.skill_id))
        {
            self.trace.add(
                Stage::Replan,
                "rejected an action outside the task graph ready set",
                json!({ "skill_id": invalid.skill_id, "ready_set": ready_skill_ids }),
            );
            if self.replan_attempts < self.config.policy.max_replans {
                self.replan_attempts += 1;
                return Ok(self.replan_command());
            }
        }
        let calls: Vec<SkillCall> = next
            .skill_calls
            .into_iter()
            .filter(|call| ready_skill_ids.contains(&call.skill_id))
            .take(1)
            .collect();
        let clarification = next.clarification;
        let plan = self.plan.as_mut().expect("plan exists");
        plan.skill_calls = calls;
        plan.clarification = clarification;
        self.next_skill_index = 0;
        self.trace.add(Stage::Replan, "selected bounded next action", json!({ "attempt": self.replan_attempts, "skill_calls": plan.skill_calls.len(), "has_clarification": plan.clarification.is_some() }));
        self.route_plan()
    }

    fn after_plan_without_skills(&mut self) -> ExecutionStep {
        if let Some(scope) = self.config.memory_scope.clone() {
            let request_id = self.allocate_request_id();
            self.pending = Pending::MemorySearch(request_id);
            return ExecutionStep::Command(ExecutionCommand::SearchMemory {
                protocol_version: EXECUTION_PROTOCOL_VERSION.into(),
                request_id,
                query: self.context_query(),
                scope,
                limit: self.config.policy.max_sources,
            });
        }
        self.after_memory()
    }

    fn normalize_source_ids(&mut self) {
        for (index, source) in self.sources.iter_mut().enumerate() {
            source.id = format!("S{}", index + 1);
        }
    }

    fn answer_command(&mut self) -> ExecutionStep {
        let context = compile_context(
            None,
            &self.memories,
            &self.sources,
            ContextBudget::from_total(self.config.policy.max_context_chars),
        );
        let plan = self.plan.as_ref().expect("plan exists");
        let plan_json = serde_json::to_string_pretty(plan).expect("plan serializes");
        let request_id = self.allocate_request_id();
        self.pending = Pending::Answer(request_id);
        ExecutionStep::Command(ExecutionCommand::Generate {
            protocol_version: EXECUTION_PROTOCOL_VERSION.into(),
            request_id,
            stage: Stage::Generate,
            request: GenerationRequest {
                messages: vec![
                    Message::system(ANSWER_SYSTEM_PROMPT),
                    Message::user(format!(
                        "QUERY:\n{}\n\nPLAN:\n{plan_json}\n\nLOCAL MEMORY:\n{}\n\nLOCAL SOURCES:\n{}{}",
                        self.query,
                        if context.memory.is_empty() {
                            "(none)"
                        } else {
                            &context.memory
                        },
                        if context.sources.is_empty() {
                            "(none)"
                        } else {
                            &context.sources
                        },
                        output_instruction(self.config.output_schema.as_ref())
                    )),
                ],
                schema: Some(answer_schema(self.config.output_schema.as_ref())),
                temperature: 0.1,
                max_tokens: None,
                reasoning_effort: Some("none".into()),
                timeout_ms: self.config.policy.request_timeout_ms,
            },
        })
    }

    fn accept_answer(&mut self, response: GenerationResponse) -> OperonResult<ExecutionStep> {
        match parse_model_json(&response.text) {
            Ok(payload) => self.validate_or_repair(payload),
            Err(error)
                if self.config.policy.verification != Strategy::Never
                    && self.config.policy.max_repair_attempts > 0 =>
            {
                let error = error.to_string();
                self.trace.add(
                    Stage::Validate,
                    "candidate was not structured JSON",
                    json!({ "errors": [&error] }),
                );
                Ok(self.repair_command(json!({ "raw_output": response.text }), vec![error]))
            }
            Err(error) => Err(error),
        }
    }

    fn accept_repair(&mut self, response: GenerationResponse) -> OperonResult<ExecutionStep> {
        let payload: AnswerPayload = parse_model_json(&response.text)?;
        self.validate_or_repair(payload)
    }

    fn validate_or_repair(&mut self, mut payload: AnswerPayload) -> OperonResult<ExecutionStep> {
        if normalize_confidence(&mut payload) {
            self.was_repaired = true;
            self.trace.add(
                Stage::Repair,
                "normalized percentage-style confidence",
                json!({}),
            );
        }
        if self.config.policy.verification == Strategy::Never {
            let errors = validate_output(&payload, self.config.output_schema.as_ref());
            self.trace.add(
                Stage::Validate,
                "semantic verification disabled; structural contract already parsed",
                json!({ "errors": errors }),
            );
            if !errors.is_empty() {
                return Err(OperonError::Validation(errors));
            }
            return self.validate_with_host_or_complete(payload);
        }

        let plan = self.plan.as_ref().expect("plan exists");
        let mut errors = validate_answer(
            &payload,
            plan,
            &self.sources,
            self.config.output_schema.as_ref(),
        );
        self.trace.add(
            Stage::Validate,
            "validated candidate answer",
            json!({ "errors": errors }),
        );
        if !errors.is_empty() && normalize_citations(&mut payload, &self.sources) {
            self.was_repaired = true;
            self.trace.add(
                Stage::Repair,
                "normalized valid source citations deterministically",
                json!({}),
            );
            errors = validate_answer(
                &payload,
                plan,
                &self.sources,
                self.config.output_schema.as_ref(),
            );
            self.trace.add(
                Stage::Validate,
                "validated deterministic repair",
                json!({ "errors": errors }),
            );
        }
        if errors.is_empty() {
            return self.validate_with_host_or_complete(payload);
        }
        if self.repair_attempts >= self.config.policy.max_repair_attempts {
            return Err(OperonError::Validation(errors));
        }
        let candidate = serde_json::to_value(&payload)
            .map_err(|error| OperonError::InvalidModelOutput(error.to_string()))?;
        Ok(self.repair_command(candidate, errors))
    }

    fn validate_with_host_or_complete(
        &mut self,
        payload: AnswerPayload,
    ) -> OperonResult<ExecutionStep> {
        if !self.config.has_application_validator {
            return Ok(self.complete(payload));
        }
        let output = payload.output.clone().ok_or_else(|| {
            OperonError::Validation(vec![
                "application validation requires a configured output schema".into(),
            ])
        })?;
        self.pending_payload = Some(payload);
        let request_id = self.allocate_request_id();
        self.pending = Pending::ApplicationValidation(request_id);
        Ok(ExecutionStep::Command(ExecutionCommand::ValidateOutput {
            protocol_version: EXECUTION_PROTOCOL_VERSION.into(),
            request_id,
            output,
        }))
    }

    fn accept_application_validation(
        &mut self,
        errors: Vec<String>,
    ) -> OperonResult<ExecutionStep> {
        let payload = self.pending_payload.take().ok_or_else(|| {
            OperonError::InvalidRequest("application validation has no pending payload".into())
        })?;
        self.trace.add(
            Stage::Validate,
            "validated application output",
            json!({ "errors": errors }),
        );
        if errors.is_empty() {
            return Ok(self.complete(payload));
        }
        if self.repair_attempts >= self.config.policy.max_repair_attempts {
            return Err(OperonError::Validation(errors));
        }
        let candidate = serde_json::to_value(&payload)
            .map_err(|error| OperonError::InvalidModelOutput(error.to_string()))?;
        Ok(self.repair_command(candidate, errors))
    }

    fn repair_command(&mut self, candidate: Value, errors: Vec<String>) -> ExecutionStep {
        self.was_repaired = true;
        self.repair_attempts += 1;
        let plan = self.plan.as_ref().expect("plan exists");
        let plan_json = serde_json::to_string_pretty(plan).expect("plan serializes");
        let error_text = errors
            .iter()
            .map(|error| format!("- {error}"))
            .collect::<Vec<_>>()
            .join("\n");
        let request_id = self.allocate_request_id();
        self.pending = Pending::Repair(request_id);
        ExecutionStep::Command(ExecutionCommand::Generate {
            protocol_version: EXECUTION_PROTOCOL_VERSION.into(),
            request_id,
            stage: Stage::Repair,
            request: GenerationRequest {
                messages: vec![
                    Message::system(REPAIR_SYSTEM_PROMPT),
                    Message::user(format!(
                        "QUERY:\n{}\n\nPLAN:\n{plan_json}\n\nSOURCES:\n{}\n\nCANDIDATE:\n{candidate}\n\nVALIDATION ERRORS:\n{error_text}{}",
                        self.query,
                        format_sources(&self.sources, self.config.policy.max_context_chars),
                        output_instruction(self.config.output_schema.as_ref())
                    )),
                ],
                schema: Some(answer_schema(self.config.output_schema.as_ref())),
                temperature: 0.0,
                max_tokens: None,
                reasoning_effort: Some("none".into()),
                timeout_ms: self.config.policy.request_timeout_ms,
            },
        })
    }

    fn complete(&mut self, payload: AnswerPayload) -> ExecutionStep {
        let declared_source_ids = payload.used_source_ids.clone();
        let used_ids: BTreeSet<&str> = payload.used_source_ids.iter().map(String::as_str).collect();
        let sources = self
            .sources
            .iter()
            .filter(|source| used_ids.contains(source.id.as_str()))
            .cloned()
            .collect();
        self.pending = Pending::Complete;
        ExecutionStep::Complete(Box::new(ExecutionResult {
            protocol_version: EXECUTION_PROTOCOL_VERSION.into(),
            answer: payload.answer.trim().to_owned(),
            output: payload.output,
            sources,
            confidence: payload.confidence,
            plan: self.plan.clone().expect("plan exists"),
            trace: std::mem::take(&mut self.trace.events),
            declared_source_ids,
            was_repaired: self.was_repaired,
            clarification: None,
            skill_receipts: self.skill_receipts.clone(),
        }))
    }

    fn complete_clarification(&mut self, clarification: Clarification) -> ExecutionStep {
        self.trace.add(
            Stage::Validate,
            "completed with structured clarification",
            json!({
                "skill_id": clarification.skill_id, "missing_fields": clarification.missing_fields,
            }),
        );
        self.pending = Pending::Complete;
        ExecutionStep::Complete(Box::new(ExecutionResult {
            protocol_version: EXECUTION_PROTOCOL_VERSION.into(),
            answer: clarification.prompt.clone(),
            output: None,
            sources: Vec::new(),
            confidence: 1.0,
            plan: self.plan.clone().expect("plan exists"),
            trace: std::mem::take(&mut self.trace.events),
            declared_source_ids: Vec::new(),
            was_repaired: false,
            clarification: Some(clarification),
            skill_receipts: self.skill_receipts.clone(),
        }))
    }

    fn trace_generation(&mut self, stage: Stage, response: &GenerationResponse) {
        let context_chars = format_sources(&self.sources, self.config.policy.max_context_chars)
            .chars()
            .count();
        let mut data = usage_data(response);
        data["context_chars"] = json!(context_chars);
        self.trace.add(stage, "generated candidate answer", data);
    }

    fn allocate_request_id(&mut self) -> u64 {
        let request_id = self.next_request_id;
        self.next_request_id += 1;
        request_id
    }
}

fn usage_data(response: &GenerationResponse) -> Value {
    json!({
        "prompt_tokens": response.prompt_tokens,
        "completion_tokens": response.completion_tokens,
        "finish_reason": response.finish_reason
    })
}

fn plan_schema_for(ready_skill_ids: &BTreeSet<String>) -> Value {
    let mut schema = plan_schema();
    if !ready_skill_ids.is_empty() {
        schema["properties"]["skill_calls"]["items"]["properties"]["skill_id"]["enum"] =
            json!(ready_skill_ids.iter().collect::<Vec<_>>());
    }
    schema
}
