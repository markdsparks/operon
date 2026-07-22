from __future__ import annotations

import json
import tempfile
import unittest
from collections import deque
from pathlib import Path

from operon import (
    LocalDocuments,
    Operon,
    OperonValidationError,
    Policy,
    Skill,
    SkillDescriptor,
    SkillRegistry,
    SkillResult,
    SkillPreparation,
    SessionArtifact,
)
from operon.models import (
    GenerationRequest,
    GenerationResponse,
    ModelCapabilities,
    Stage,
)


class ScriptedProvider:
    def __init__(self, responses: list[dict[str, object]]) -> None:
        self.responses = deque(json.dumps(response) for response in responses)
        self.requests: list[GenerationRequest] = []

    @property
    def capabilities(self) -> ModelCapabilities:
        return ModelCapabilities(structured_output=True, privacy="local")

    def generate(self, request: GenerationRequest) -> GenerationResponse:
        self.requests.append(request)
        return GenerationResponse(self.responses.popleft())


class OperonTests(unittest.TestCase):
    def test_fast_path_wraps_simple_query(self) -> None:
        provider = ScriptedProvider(
            [{"answer": "Four.", "confidence": 0.99, "used_source_ids": []}]
        )
        runtime = Operon.wrap(provider, policy=Policy(planning="adaptive"))

        response = runtime.run("What is two plus two?")

        self.assertEqual(response.answer, "Four.")
        self.assertFalse(response.was_repaired)
        self.assertEqual(len(provider.requests), 1)
        self.assertEqual(response.trace.events[0].stage, Stage.CLASSIFY)

    def test_runs_registered_skill_before_answer_and_cites_its_result(self) -> None:
        provider = ScriptedProvider(
            [
                {
                    "intent": "Check the live application state",
                    "subquestions": [],
                    "needs_grounding": False,
                    "answer_requirements": [],
                    "skill_calls": [
                        {"skill_id": "calendar.availability", "arguments": {"day": "Friday"}}
                    ],
                },
                {
                    "answer": "Friday is open [S1].",
                    "confidence": 0.9,
                    "used_source_ids": ["S1"],
                },
            ]
        )
        skills = SkillRegistry(
            [
                Skill(
                    SkillDescriptor(
                        id="calendar.availability",
                        description="Read the app's calendar snapshot.",
                        input_schema={
                            "type": "object", "properties": {"day": {"type": "string"}},
                            "required": ["day"], "additionalProperties": False,
                        },
                        output_schema={
                            "type": "object", "properties": {"open": {"type": "boolean"}},
                            "required": ["open"], "additionalProperties": False,
                        },
                    ),
                    lambda arguments: SkillResult({"open": arguments["day"] == "Friday"}),
                )
            ]
        )
        response = Operon(provider, policy=Policy(planning="always"), skills=skills).run(
            "Am I free Friday?"
        )

        self.assertEqual(response.answer, "Friday is open [S1].")
        self.assertEqual(response.sources[0].path, "skill://calendar.availability")
        self.assertIn(Stage.SKILL, [event.stage for event in response.trace.events])

    def test_prepares_partial_skill_call_from_typed_session_artifact(self) -> None:
        provider = ScriptedProvider([
            {"intent": "open hourly", "subquestions": [], "needs_grounding": False,
             "answer_requirements": [], "skill_calls": [{"skill_id": "view.hourly", "arguments": {"window_ref": "last_result"}}]},
            {"answer": "Opened [S1].", "confidence": 0.9, "used_source_ids": ["S1"]},
        ])
        descriptor = SkillDescriptor(
            id="view.hourly", description="Open a weather hourly view.",
            input_schema={"type": "object", "properties": {"place": {"type": "string"}, "date": {"type": "string"}}, "required": ["place", "date"], "additionalProperties": False},
            output_schema={"type": "object", "properties": {"opened": {"type": "boolean"}}, "required": ["opened"], "additionalProperties": False},
        )
        skills = SkillRegistry([Skill(
            descriptor, lambda _: SkillResult({"opened": True}),
            prepare=lambda partial, artifacts: SkillPreparation.ready({"place": artifacts[0].value["place"], "date": artifacts[0].value["date"]}),
        )])
        response = Operon(provider, policy=Policy(planning="always"), skills=skills).run(
            "Show the hourly view for that.",
            session_artifacts=(SessionArtifact("window-1", "forecast-window", "Nokomis tomorrow evening", {"place": "Nokomis", "date": "2026-07-23"}),),
        )
        self.assertEqual(response.sources[0].path, "skill://view.hourly")
        self.assertIn("Nokomis tomorrow evening", provider.requests[0].messages[1]["content"])

    def test_normalizes_percentage_style_confidence_without_retry(self) -> None:
        provider = ScriptedProvider(
            [{"answer": "Four.", "confidence": 90, "used_source_ids": []}]
        )
        runtime = Operon.wrap(provider, policy=Policy(planning="never"))

        response = runtime.run("What is two plus two?")

        self.assertEqual(response.confidence, 0.9)
        self.assertTrue(response.was_repaired)
        self.assertEqual(len(provider.requests), 1)

    def test_validates_and_repairs_application_typed_output(self) -> None:
        output_schema = {
            "type": "object",
            "properties": {
                "decision": {"type": "string", "enum": ["allow", "deny"]},
                "amount": {"type": "number", "minimum": 0},
            },
            "required": ["decision", "amount"],
            "additionalProperties": False,
        }
        provider = ScriptedProvider(
            [
                {
                    "answer": "It may proceed.",
                    "confidence": 0.8,
                    "used_source_ids": [],
                    "output": {"decision": "maybe", "amount": -1},
                },
                {
                    "answer": "It may proceed.",
                    "confidence": 0.8,
                    "used_source_ids": [],
                    "output": {"decision": "allow", "amount": 68},
                },
            ]
        )
        runtime = Operon.wrap(
            provider,
            policy=Policy(planning="never"),
            output_schema=output_schema,
        )

        response = runtime.run("Determine the reimbursable amount.")

        self.assertEqual(response.output, {"decision": "allow", "amount": 68})
        self.assertTrue(response.was_repaired)
        request_schema = provider.requests[0].schema
        self.assertEqual(
            request_schema["properties"]["output"]["properties"]["decision"]["enum"],
            ["allow", "deny"],
        )

    def test_rejects_unsupported_output_schema_before_inference(self) -> None:
        provider = ScriptedProvider([])

        with self.assertRaisesRegex(ValueError, "unsupported keywords: anyOf"):
            Operon.wrap(provider, output_schema={"type": "string", "anyOf": []})

    def test_plans_grounds_and_repairs_invalid_citations(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            policy_path = Path(directory) / "refunds.md"
            policy_path.write_text(
                "Customers may request a refund within 30 days when they have a receipt.",
                encoding="utf-8",
            )
            provider = ScriptedProvider(
                [
                    {
                        "intent": "Determine refund eligibility",
                        "subquestions": ["When was the purchase?", "Is there a receipt?"],
                        "needs_grounding": True,
                        "answer_requirements": ["Apply the refund policy"],
                    },
                    {
                        "answer": "The request qualifies [S9].",
                        "confidence": 0.8,
                        "used_source_ids": ["S9"],
                    },
                    {
                        "answer": "The policy allows a refund within 30 days with a receipt [S1].",
                        "confidence": 0.9,
                        "used_source_ids": ["S1"],
                    },
                ]
            )
            runtime = Operon(
                provider,
                grounding=LocalDocuments(policy_path),
                policy=Policy(planning="always", max_repair_attempts=1),
            )

            response = runtime.run(
                "Analyze whether a customer with a receipt can obtain a refund within 20 days."
            )

            self.assertTrue(response.was_repaired)
            self.assertEqual([source.id for source in response.sources], ["S1"])
            self.assertIn("[S1]", response.answer)
            self.assertEqual(len(provider.requests), 3)
            self.assertIn(Stage.REPAIR, [event.stage for event in response.trace.events])

    def test_planner_cannot_veto_explicit_grounding(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            policy_path = Path(directory) / "policy.md"
            policy_path.write_text("The current limit is two days.", encoding="utf-8")
            provider = ScriptedProvider(
                [
                    {
                        "intent": "Determine the current limit",
                        "subquestions": [],
                        "needs_grounding": False,
                        "answer_requirements": [],
                    },
                    {
                        "answer": "The current limit is two days [S1].",
                        "confidence": 0.9,
                        "used_source_ids": ["S1"],
                    },
                ]
            )
            runtime = Operon(
                provider,
                grounding=LocalDocuments(policy_path),
                policy=Policy(planning="always"),
            )

            response = runtime.run("Analyze the current limit in the policy.")

            self.assertEqual([source.id for source in response.sources], ["S1"])
            classify = response.trace.events[0]
            self.assertTrue(classify.data["needs_grounding"])
            self.assertFalse(classify.data["model_requested_grounding"])

    def test_local_policy_rejects_remote_provider(self) -> None:
        provider = ScriptedProvider([])
        provider.capabilities  # Verify the test double contract before overriding.

        class RemoteProvider(ScriptedProvider):
            @property
            def capabilities(self) -> ModelCapabilities:
                return ModelCapabilities(privacy="remote")

        with self.assertRaisesRegex(ValueError, "local_only"):
            Operon(RemoteProvider([]))

    def test_repairs_malformed_json(self) -> None:
        class RawScriptedProvider(ScriptedProvider):
            def __init__(self) -> None:
                super().__init__([
                    {"answer": "Recovered.", "confidence": 0.7, "used_source_ids": []}
                ])
                self.first = True

            def generate(self, request: GenerationRequest) -> GenerationResponse:
                self.requests.append(request)
                if self.first:
                    self.first = False
                    return GenerationResponse("This was not JSON")
                return GenerationResponse(self.responses.popleft())

        response = Operon(
            RawScriptedProvider(), policy=Policy(planning="never", max_repair_attempts=1)
        ).run("Give me a short greeting")

        self.assertEqual(response.answer, "Recovered.")
        self.assertTrue(response.was_repaired)

    def test_terminal_validation_error_retains_candidate_and_trace(self) -> None:
        provider = ScriptedProvider(
            [{"answer": "Bad citation [S9].", "confidence": 0.5, "used_source_ids": ["S9"]}]
        )
        runtime = Operon(
            provider, policy=Policy(planning="never", max_repair_attempts=0)
        )

        with self.assertRaises(OperonValidationError) as captured:
            runtime.run("Give me a greeting")

        self.assertEqual(captured.exception.candidate["used_source_ids"], ["S9"])
        self.assertTrue(captured.exception.trace.events)

    def test_normalizes_missing_valid_citation_without_model_retry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            policy_path = Path(directory) / "refunds.md"
            policy_path.write_text("Refunds are allowed for 30 days.", encoding="utf-8")
            provider = ScriptedProvider(
                [
                    {
                        "answer": "The policy allows a refund.",
                        "confidence": 0.8,
                        "used_source_ids": ["S1"],
                    }
                ]
            )
            runtime = Operon(
                provider,
                grounding=LocalDocuments(policy_path),
                policy=Policy(planning="never", max_repair_attempts=0),
            )

            response = runtime.run("What does the refund policy allow?")

            self.assertEqual(response.answer, "The policy allows a refund. [S1]")
            self.assertTrue(response.was_repaired)
            self.assertEqual(len(provider.requests), 1)

    def test_verification_never_preserves_unverified_citation_output(self) -> None:
        provider = ScriptedProvider(
            [
                {
                    "answer": "An unverified answer without inline markers.",
                    "confidence": 0.6,
                    "used_source_ids": ["S9"],
                }
            ]
        )
        runtime = Operon(
            provider,
            policy=Policy(
                planning="never", verification="never", max_repair_attempts=1
            ),
        )

        response = runtime.run("Give me an answer")

        self.assertEqual(response.answer, "An unverified answer without inline markers.")
        self.assertFalse(response.was_repaired)
        self.assertEqual(len(provider.requests), 1)


if __name__ == "__main__":
    unittest.main()
