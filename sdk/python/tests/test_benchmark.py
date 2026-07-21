from __future__ import annotations

import unittest
import json
import tempfile
from dataclasses import asdict
from pathlib import Path

from benchmarks.compare import Profile, comparison, estimated_cost, load_profiles
from benchmarks.matrix import aggregate_matrix, model_slug
from benchmarks.run import (
    PROTOCOL_VERSION,
    Case,
    RunRecord,
    case_digest,
    load_cases,
    score_answer,
    summarize,
)


class BenchmarkTests(unittest.TestCase):
    def test_all_benchmark_fixtures_exist(self) -> None:
        cases = load_cases(Path("benchmarks/cases.json"))

        self.assertGreaterEqual(len(cases), 5)
        self.assertTrue(all(path.is_file() for case in cases for path in case.documents))
        self.assertTrue(all(len(case_digest(case)) == 64 for case in cases))
        self.assertEqual(PROTOCOL_VERSION, "1.0")

    def test_phrase_and_source_scoring(self) -> None:
        case = Case(
            id="case",
            title="Case",
            expected_verdict="deny",
            query="Question",
            documents=(),
            required_any=(("not eligible", "cannot be returned"), ("final sale",)),
            forbidden_any=("is eligible",),
            expected_sources=("policy.md",),
        )

        correct, complete, required, forbidden, recall, precision = score_answer(
            case,
            "The item cannot be returned because it is final sale [S1].",
            ["fixtures/policy.md"],
        )

        self.assertTrue(correct)
        self.assertTrue(complete)
        self.assertEqual(required, [True, True])
        self.assertTrue(forbidden)
        self.assertEqual(recall, 1.0)
        self.assertEqual(precision, 1.0)

    def test_summary_counts_failures_as_incorrect(self) -> None:
        base = {
            "timestamp": "now",
            "model": "model",
            "case_id": "case",
            "case_title": "Case",
            "configuration": "operon_full",
            "repetition": 1,
        }
        records = [
            RunRecord(**base, success=True, correct=True, duration_ms=10, model_calls=2),
            RunRecord(**base, success=False, correct=False, duration_ms=20, model_calls=0),
        ]

        result = summarize(records)["operon_full"]

        self.assertEqual(result["accuracy"], 0.5)
        self.assertEqual(result["success_rate"], 0.5)
        self.assertEqual(result["average_latency_ms"], 15)

    def test_terse_no_is_correct_but_incomplete_for_denial(self) -> None:
        case = Case(
            id="case",
            title="Case",
            expected_verdict="deny",
            query="Question",
            documents=(),
            required_any=(("not eligible",), ("controlling rule",)),
            forbidden_any=("is eligible",),
            expected_sources=(),
        )

        correct, complete, *_ = score_answer(case, "No [S2]", [])

        self.assertTrue(correct)
        self.assertFalse(complete)

    def test_explicit_exact_numeric_answer_is_correct_but_incomplete(self) -> None:
        case = Case(
            id="case",
            title="Numeric answer",
            expected_verdict="duration",
            query="How many days?",
            documents=(),
            required_any=(("two days",), ("current policy",)),
            forbidden_any=(),
            expected_sources=(),
            accepted_exact=("2", "two"),
        )

        correct, complete, *_ = score_answer(case, "2 [S1]", [])

        self.assertTrue(correct)
        self.assertFalse(complete)

    def test_matrix_aggregates_saved_records(self) -> None:
        record = RunRecord(
            timestamp="now",
            model="model:1b",
            case_id="case",
            case_title="Case",
            configuration="operon_full",
            repetition=1,
            success=True,
            correct=True,
            complete=True,
            duration_ms=10,
            model_calls=2,
            case_digest="abc",
            run_id="run",
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "model.jsonl"
            path.write_text(json.dumps(asdict(record)) + "\n", encoding="utf-8")

            result = aggregate_matrix({"model:1b": path})

        self.assertEqual(model_slug("model:1b"), "model-1b")
        self.assertEqual(result["model:1b"]["runs"], 1)
        self.assertEqual(result["model:1b"]["summary"]["operon_full"]["accuracy"], 1)

    def test_profile_comparison_keeps_cost_assumptions_explicit(self) -> None:
        record = RunRecord(
            timestamp="now", model="cloud", profile="cloud-reference", case_id="case",
            case_title="Case", configuration="operon_full", repetition=1, success=True,
            correct=True, duration_ms=100, model_calls=2, prompt_tokens=1_000,
            completion_tokens=500,
        )
        profile = Profile(
            name="cloud-reference", model="cloud", base_url="https://example.invalid/v1",
            input_cost_per_million=2, output_cost_per_million=4,
        )
        self.assertEqual(estimated_cost(record, profile), 0.004)
        result = comparison([record], [profile])
        self.assertEqual(
            result["cloud-reference"]["summary"]["operon_full"]["estimated_average_cost_usd"],
            0.004,
        )

    def test_remote_profile_requires_explicit_opt_in(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "profiles.json"
            path.write_text(
                json.dumps(
                    [
                        {
                            "name": "default",
                            "model": "local",
                            "base_url": "http://127.0.0.1:11434/v1",
                        },
                        {
                            "name": "remote-reference",
                            "model": "cloud",
                            "base_url": "https://example.invalid/v1",
                            "allow_remote": True,
                            "completion_token_parameter": "max_completion_tokens",
                        },
                    ]
                ),
                encoding="utf-8",
            )
            default, remote = load_profiles(path)

        self.assertFalse(default.allow_remote)
        self.assertTrue(remote.allow_remote)
        self.assertEqual(remote.completion_token_parameter, "max_completion_tokens")


if __name__ == "__main__":
    unittest.main()
