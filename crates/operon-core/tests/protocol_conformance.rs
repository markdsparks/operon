use std::fs;
use std::path::PathBuf;

use operon_core::{
    ExecutionCommand, ExecutionEvent, ExecutionPolicy, ExecutionSession, ExecutionStep,
    MemoryScope, MemorySensitivity, SessionConfig, SkillDescriptor, SkillResult, Stage, Strategy,
};
use serde::Deserialize;
use serde_json::json;

#[derive(Deserialize)]
struct Fixture {
    name: String,
    query: String,
    events: Vec<ExecutionEvent>,
    expected_commands: Vec<String>,
    expected_answer: String,
    expected_source_ids: Vec<String>,
    expected_was_repaired: bool,
}

#[test]
fn replays_refund_grounding_repair_fixture() {
    let fixture = load_fixture("refund_grounding_repair.json");
    let mut session = ExecutionSession::new(
        &fixture.query,
        SessionConfig {
            policy: ExecutionPolicy {
                planning: Strategy::Always,
                ..ExecutionPolicy::default()
            },
            has_grounding: true,
            output_schema: None,
            has_application_validator: false,
            memory_scope: None,
            skills: vec![],
        },
    )
    .unwrap();

    let mut step = session.start().unwrap();
    let mut commands = Vec::new();
    let mut events = fixture.events.into_iter();
    let result = loop {
        match step {
            ExecutionStep::Command(command) => {
                let serialized = serde_json::to_value(&command).unwrap();
                assert_eq!(serialized["protocol_version"], "0.1");
                assert!(serialized["request_id"].as_u64().unwrap() >= 1);
                commands.push(command_label(&command));
                let event = events.next().expect("fixture event for every command");
                assert_eq!(
                    event_request_id(&event),
                    command.request_id(),
                    "{}",
                    fixture.name
                );
                step = session.resume(event).unwrap();
            }
            ExecutionStep::Complete(result) => break result,
        }
    };

    assert!(events.next().is_none());
    assert_eq!(commands, fixture.expected_commands);
    assert_eq!(result.answer, fixture.expected_answer);
    assert_eq!(result.declared_source_ids, fixture.expected_source_ids);
    assert_eq!(result.was_repaired, fixture.expected_was_repaired);
    assert!(result.plan.needs_grounding);
    let serialized_result = serde_json::to_value(&*result).unwrap();
    assert_eq!(serialized_result["protocol_version"], "0.1");
}

#[test]
fn rejects_an_event_for_a_different_request() {
    let mut session = ExecutionSession::new(
        "Analyze this request using policy.",
        SessionConfig {
            policy: ExecutionPolicy {
                planning: Strategy::Always,
                ..ExecutionPolicy::default()
            },
            ..SessionConfig::default()
        },
    )
    .unwrap();
    let _ = session.start().unwrap();
    let error = session
        .resume(ExecutionEvent::GenerationCompleted {
            protocol_version: "0.1".into(),
            request_id: 99,
            response: operon_core::GenerationResponse::text("{}"),
        })
        .unwrap_err();

    assert!(
        error
            .to_string()
            .contains("does not match outstanding command")
    );
}

#[test]
fn application_validation_errors_trigger_a_targeted_repair() {
    let mut session = ExecutionSession::new(
        "Decide whether the expense is allowed.",
        SessionConfig {
            policy: ExecutionPolicy {
                planning: Strategy::Never,
                ..ExecutionPolicy::default()
            },
            has_grounding: false,
            output_schema: Some(json!({
                "type": "object",
                "properties": { "decision": { "type": "string" } },
                "required": ["decision"],
                "additionalProperties": false
            })),
            has_application_validator: true,
            memory_scope: None,
            skills: vec![],
        },
    )
    .unwrap();

    let first_id = match session.start().unwrap() {
        ExecutionStep::Command(ExecutionCommand::Generate { request_id, .. }) => request_id,
        _ => panic!("expected initial generation"),
    };
    let validation_id = match session
        .resume(ExecutionEvent::GenerationCompleted {
            protocol_version: "0.1".into(),
            request_id: first_id,
            response: operon_core::GenerationResponse::text(
                r#"{"answer":"Deny.","confidence":0.9,"used_source_ids":[],"output":{"decision":"deny"}}"#,
            ),
        })
        .unwrap()
    {
        ExecutionStep::Command(ExecutionCommand::ValidateOutput {
            request_id, output, ..
        }) => {
            assert_eq!(output["decision"], "deny");
            request_id
        }
        _ => panic!("expected application validation"),
    };
    let repair_id = match session
        .resume(ExecutionEvent::OutputValidated {
            protocol_version: "0.1".into(),
            request_id: validation_id,
            errors: vec!["decision must be partial when alcohol is present".into()],
        })
        .unwrap()
    {
        ExecutionStep::Command(ExecutionCommand::Generate {
            request_id, stage, ..
        }) => {
            assert_eq!(stage, Stage::Repair);
            request_id
        }
        _ => panic!("expected repair generation"),
    };
    let final_validation_id = match session
        .resume(ExecutionEvent::GenerationCompleted {
            protocol_version: "0.1".into(),
            request_id: repair_id,
            response: operon_core::GenerationResponse::text(
                r#"{"answer":"Allow food only.","confidence":0.9,"used_source_ids":[],"output":{"decision":"partial"}}"#,
            ),
        })
        .unwrap()
    {
        ExecutionStep::Command(ExecutionCommand::ValidateOutput { request_id, .. }) => request_id,
        _ => panic!("expected final application validation"),
    };
    let result = match session
        .resume(ExecutionEvent::OutputValidated {
            protocol_version: "0.1".into(),
            request_id: final_validation_id,
            errors: vec![],
        })
        .unwrap()
    {
        ExecutionStep::Complete(result) => result,
        _ => panic!("expected completion"),
    };
    assert!(result.was_repaired);
    assert_eq!(result.output.unwrap()["decision"], "partial");
}

#[test]
fn memory_scope_yields_search_before_generation_and_enters_context() {
    let scope = MemoryScope {
        namespace: "customer-42".into(),
        subject: None,
        allowed_sensitivities: vec![MemorySensitivity::Private],
    };
    let mut session = ExecutionSession::new(
        "How should I respond?",
        SessionConfig {
            policy: ExecutionPolicy {
                planning: Strategy::Never,
                ..ExecutionPolicy::default()
            },
            has_grounding: false,
            output_schema: None,
            has_application_validator: false,
            memory_scope: Some(scope.clone()),
            skills: vec![],
        },
    )
    .unwrap();
    let request_id = match session.start().unwrap() {
        ExecutionStep::Command(ExecutionCommand::SearchMemory {
            request_id,
            scope: command_scope,
            ..
        }) => {
            assert_eq!(command_scope, scope);
            request_id
        }
        _ => panic!("expected memory search"),
    };
    let memory = operon_core::MemoryRecord {
        id: "M1".into(),
        namespace: "customer-42".into(),
        subject: None,
        kind: operon_core::MemoryKind::Preference,
        content: "Customer prefers concise answers.".into(),
        authority: operon_core::MemoryAuthority::UserConfirmed,
        sensitivity: MemorySensitivity::Private,
        confidence: None,
        source_ids: vec![],
        occurred_at: None,
        observed_at: "2026-07-21T00:00:00Z".into(),
        valid_from: None,
        valid_until: None,
        supersedes: None,
        status: operon_core::MemoryStatus::Active,
        created_by: "application".into(),
        schema_version: 1,
    };
    match session
        .resume(ExecutionEvent::MemorySearchCompleted {
            protocol_version: "0.1".into(),
            request_id,
            records: vec![memory],
        })
        .unwrap()
    {
        ExecutionStep::Command(ExecutionCommand::Generate { request, .. }) => {
            assert!(
                request.messages[1]
                    .content
                    .contains("Customer prefers concise answers.")
            );
        }
        _ => panic!("expected answer generation"),
    }
}

fn load_fixture(name: &str) -> Fixture {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../conformance/cases")
        .join(name);
    let text = fs::read_to_string(path).expect("read conformance fixture");
    serde_json::from_str(&text).expect("parse conformance fixture")
}

fn command_label(command: &ExecutionCommand) -> String {
    match command {
        ExecutionCommand::Generate { stage, .. } => format!("generate:{}", stage_name(*stage)),
        ExecutionCommand::Retrieve { .. } => "retrieve".into(),
        ExecutionCommand::SearchMemory { .. } => "search_memory".into(),
        ExecutionCommand::ValidateOutput { .. } => "validate_output".into(),
        ExecutionCommand::InvokeSkill { .. } => "invoke_skill".into(),
    }
}

fn stage_name(stage: Stage) -> &'static str {
    match stage {
        Stage::Classify => "classify",
        Stage::Skill => "skill",
        Stage::Ground => "ground",
        Stage::Generate => "generate",
        Stage::Validate => "validate",
        Stage::Repair => "repair",
    }
}

fn event_request_id(event: &ExecutionEvent) -> u64 {
    match event {
        ExecutionEvent::GenerationCompleted { request_id, .. }
        | ExecutionEvent::RetrievalCompleted { request_id, .. }
        | ExecutionEvent::MemorySearchCompleted { request_id, .. }
        | ExecutionEvent::OutputValidated { request_id, .. }
        | ExecutionEvent::SkillCompleted { request_id, .. }
        | ExecutionEvent::CommandFailed { request_id, .. } => *request_id,
    }
}

#[test]
fn invokes_only_registered_validated_skills_and_exposes_their_result_as_context() {
    let skill = SkillDescriptor {
        id: "weather.lookup".into(),
        description: "Reads the application's weather snapshot.".into(),
        input_schema: json!({"type":"object","properties":{"place":{"type":"string"}},"required":["place"],"additionalProperties":false}),
        output_schema: json!({"type":"object","properties":{"forecast":{"type":"string"}},"required":["forecast"],"additionalProperties":false}),
        requires_user_confirmation: false,
    };
    let mut session = ExecutionSession::new(
        "Can I picnic in Madison?",
        SessionConfig {
            policy: ExecutionPolicy {
                planning: Strategy::Always,
                ..ExecutionPolicy::default()
            },
            skills: vec![skill],
            ..SessionConfig::default()
        },
    )
    .unwrap();
    let plan_id = match session.start().unwrap() {
        ExecutionStep::Command(ExecutionCommand::Generate {
            request_id,
            request,
            ..
        }) => {
            assert!(request.messages[1].content.contains("weather.lookup"));
            request_id
        }
        _ => panic!("expected planning"),
    };
    let skill_id = match session.resume(ExecutionEvent::GenerationCompleted {
        protocol_version: "0.1".into(), request_id: plan_id,
        response: operon_core::GenerationResponse::text(r#"{"intent":"check forecast","subquestions":[],"needs_grounding":false,"answer_requirements":[],"skill_calls":[{"skill_id":"weather.lookup","arguments":{"place":"Madison"}}]}"#),
    }).unwrap() {
        ExecutionStep::Command(ExecutionCommand::InvokeSkill { request_id, skill_id, arguments, .. }) => {
            assert_eq!(skill_id, "weather.lookup"); assert_eq!(arguments["place"], "Madison"); request_id
        }
        _ => panic!("expected skill invocation"),
    };
    match session
        .resume(ExecutionEvent::SkillCompleted {
            protocol_version: "0.1".into(),
            request_id: skill_id,
            result: SkillResult {
                output: json!({"forecast":"Dry until 4pm"}),
                sources: vec![],
            },
        })
        .unwrap()
    {
        ExecutionStep::Command(ExecutionCommand::Generate { request, stage, .. }) => {
            assert_eq!(stage, Stage::Generate);
            assert!(
                request.messages[1]
                    .content
                    .contains("skill://weather.lookup")
            );
            assert!(request.messages[1].content.contains("Dry until 4pm"));
        }
        _ => panic!("expected answer generation"),
    }
}
