use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::runtime::{
    ANSWER_SYSTEM_PROMPT, AnswerPayload, PLAN_SYSTEM_PROMPT, REPAIR_SYSTEM_PROMPT, answer_schema,
    format_sources, is_complex, normalize_citations, normalize_confidence, output_instruction,
    parse_model_json, plan_schema, validate_answer, validate_output, validate_schema_definition,
};
use crate::{
    ExecutionPolicy, ExecutionTrace, GenerationRequest, GenerationResponse, MemoryRecord,
    MemoryScope, Message, OperonError, OperonResponse, OperonResult, Plan, Source, Stage, Strategy,
    TraceEvent,
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
}

impl ExecutionCommand {
    pub fn request_id(&self) -> u64 {
        match self {
            Self::Generate { request_id, .. }
            | Self::Retrieve { request_id, .. }
            | Self::SearchMemory { request_id, .. } => *request_id,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostFailureKind {
    Provider,
    Grounding,
    Memory,
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
}

#[derive(Debug)]
enum Pending {
    None,
    Plan(u64),
    Retrieval(u64),
    Answer(u64),
    Repair(u64),
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
    repair_attempts: usize,
    was_repaired: bool,
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
        Ok(Self {
            query: query.trim().to_owned(),
            config,
            trace: ExecutionTrace::default(),
            pending: Pending::None,
            next_request_id: 1,
            plan: None,
            sources: Vec::new(),
            repair_attempts: 0,
            was_repaired: false,
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
            | Pending::Answer(id)
            | Pending::Repair(id) => id,
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
                self.sources = sources;
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
                    Message::user(&self.query),
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
            }),
        );
        self.plan = Some(plan);
        Ok(self.after_plan())
    }

    fn after_plan(&mut self) -> ExecutionStep {
        if self.config.has_grounding {
            let plan = self.plan.as_ref().expect("plan exists");
            let retrieval_query = std::iter::once(self.query.as_str())
                .chain(std::iter::once(plan.intent.as_str()))
                .chain(plan.subquestions.iter().map(String::as_str))
                .collect::<Vec<_>>()
                .join("\n");
            let request_id = self.allocate_request_id();
            self.pending = Pending::Retrieval(request_id);
            ExecutionStep::Command(ExecutionCommand::Retrieve {
                protocol_version: EXECUTION_PROTOCOL_VERSION.into(),
                request_id,
                query: retrieval_query,
                limit: self.config.policy.max_sources,
            })
        } else {
            self.trace.add(
                Stage::Ground,
                "grounding not required",
                json!({ "sources": 0 }),
            );
            self.answer_command()
        }
    }

    fn answer_command(&mut self) -> ExecutionStep {
        let context = format_sources(&self.sources, self.config.policy.max_context_chars);
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
                        "QUERY:\n{}\n\nPLAN:\n{plan_json}\n\nLOCAL SOURCES:\n{}{}",
                        self.query,
                        if context.is_empty() {
                            "(none)"
                        } else {
                            &context
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
            return Ok(self.complete(payload));
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
