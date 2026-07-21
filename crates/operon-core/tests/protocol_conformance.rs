use std::fs;
use std::path::PathBuf;

use operon_core::{
    ExecutionCommand, ExecutionEvent, ExecutionPolicy, ExecutionSession, ExecutionStep,
    SessionConfig, Stage, Strategy,
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
    }
}

fn stage_name(stage: Stage) -> &'static str {
    match stage {
        Stage::Classify => "classify",
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
        | ExecutionEvent::CommandFailed { request_id, .. } => *request_id,
    }
}
