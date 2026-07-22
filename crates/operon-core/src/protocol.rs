use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::runtime::{
    ANSWER_SYSTEM_PROMPT, AnswerPayload, PLAN_SYSTEM_PROMPT, REPAIR_SYSTEM_PROMPT, answer_schema,
    format_sources, is_complex, normalize_citations, normalize_confidence, output_instruction,
    parse_model_json, plan_schema, validate_answer, validate_output, validate_schema_definition,
    validate_schema_instance,
};
use crate::{
    ContextBudget, ExecutionPolicy, ExecutionTrace, GenerationRequest, GenerationResponse,
    MemoryRecord, MemoryScope, Message, OperonError, OperonResponse, OperonResult, Plan, SkillCall,
    SkillDescriptor, SkillResult, Source, Stage, Strategy, TraceEvent, compile_context,
};

pub const EXECUTION_PROTOCOL_VERSION: &str = "0.1";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ExecutionCommand {
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
        skill_id: String,
        arguments: Value,
        requires_user_confirmation: bool,
    },
}

impl ExecutionCommand {
    pub fn request_id(&self) -> u64 {
        match self {
            Self::Generate { request_id, .. }
            | Self::Retrieve { request_id, .. }
            | Self::SearchMemory { request_id, .. }
            | Self::ValidateOutput { request_id, .. }
            | Self::InvokeSkill { request_id, .. } => *request_id,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostFailureKind {
    Provider,
    Grounding,
    Memory,
    Skill,
    Cancelled,
    Timeout,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ExecutionEvent {
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
            Self::GenerationCompleted { request_id, .. }
            | Self::RetrievalCompleted { request_id, .. }
            | Self::MemorySearchCompleted { request_id, .. }
            | Self::OutputValidated { request_id, .. }
            | Self::SkillCompleted { request_id, .. }
            | Self::CommandFailed { request_id, .. } => *request_id,
        }
    }

    fn protocol_version(&self) -> &str {
        match self {
            Self::GenerationCompleted {
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
}

#[derive(Debug)]
enum Pending {
    None,
    Plan(u64),
    Retrieval(u64),
    MemorySearch(u64),
    Skill(u64),
    Answer(u64),
    Repair(u64),
    ApplicationValidation(u64),
    Complete,
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
    skill_sources: Vec<Source>,
    next_skill_index: usize,
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
            skill_sources: Vec::new(),
            next_skill_index: 0,
            repair_attempts: 0,
            was_repaired: false,
            pending_payload: None,
        })
    }

    pub fn start(&mut self) -> OperonResult<ExecutionStep> {
        if !matches!(self.pending, Pending::None) {
            return Err(OperonError::InvalidRequest(
                "execution session has already started".into(),
            ));
        }
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
        });
        self.trace.add(
            Stage::Classify,
            "used fast-path plan",
            json!({ "complex": false }),
        );
        Ok(self.after_plan())
    }

    pub fn resume(&mut self, event: ExecutionEvent) -> OperonResult<ExecutionStep> {
        if event.protocol_version() != EXECUTION_PROTOCOL_VERSION {
            return Err(OperonError::InvalidRequest(format!(
                "unsupported execution protocol version: {}",
                event.protocol_version()
            )));
        }
        let expected = match self.pending {
            Pending::Plan(id)
            | Pending::Retrieval(id)
            | Pending::MemorySearch(id)
            | Pending::Skill(id)
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
                HostFailureKind::Memory => OperonError::Memory(message),
                HostFailureKind::Skill => OperonError::Provider(message),
                HostFailureKind::Provider
                | HostFailureKind::Cancelled
                | HostFailureKind::Timeout => OperonError::Provider(message),
            });
        }

        match (&self.pending, event) {
            (Pending::Plan(_), ExecutionEvent::GenerationCompleted { response, .. }) => {
                self.accept_plan(response)
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
                        "QUERY:\n{}\n\nAUTHORIZED SKILLS:\n{}",
                        self.query,
                        self.skill_catalog()
                    )),
                ],
                schema: Some(plan_schema()),
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
            .retain(|call| self.is_valid_skill_call(call));
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
        Ok(self.after_plan())
    }

    fn after_plan(&mut self) -> ExecutionStep {
        if let Some(command) = self.next_skill_command() {
            return command;
        }
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

    fn skill_catalog(&self) -> String {
        if self.config.skills.is_empty() {
            return "(none)".into();
        }
        serde_json::to_string_pretty(&self.config.skills).expect("skill catalog serializes")
    }

    fn is_valid_skill_call(&self, call: &SkillCall) -> bool {
        let Some(skill) = self
            .config
            .skills
            .iter()
            .find(|skill| skill.id == call.skill_id)
        else {
            return false;
        };
        validate_schema_instance(&call.arguments, &skill.input_schema, "skill arguments").is_empty()
    }

    fn next_skill_command(&mut self) -> Option<ExecutionStep> {
        let call = self
            .plan
            .as_ref()?
            .skill_calls
            .get(self.next_skill_index)?
            .clone();
        let requires_user_confirmation = self
            .config
            .skills
            .iter()
            .find(|skill| skill.id == call.skill_id)?
            .requires_user_confirmation;
        let request_id = self.allocate_request_id();
        self.pending = Pending::Skill(request_id);
        Some(ExecutionStep::Command(ExecutionCommand::InvokeSkill {
            protocol_version: EXECUTION_PROTOCOL_VERSION.into(),
            request_id,
            skill_id: call.skill_id,
            arguments: call.arguments,
            requires_user_confirmation,
        }))
    }

    fn accept_skill_result(&mut self, result: SkillResult) -> OperonResult<ExecutionStep> {
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
        let text = serde_json::to_string_pretty(&result.output)
            .map_err(|error| OperonError::InvalidModelOutput(error.to_string()))?;
        self.skill_sources.push(Source {
            id: format!("skill-{}", self.next_skill_index + 1),
            path: format!("skill://{}", skill.id),
            text,
            score: 1.0,
        });
        self.skill_sources.extend(result.sources);
        self.trace.add(
            Stage::Skill,
            "completed application-owned skill",
            json!({ "skill_id": skill.id, "sources": self.skill_sources.len() }),
        );
        self.next_skill_index += 1;
        if let Some(command) = self.next_skill_command() {
            return Ok(command);
        }
        Ok(self.after_plan_without_skills())
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
