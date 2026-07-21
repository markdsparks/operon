from __future__ import annotations

import json
import tempfile
import unittest
from collections import deque
from pathlib import Path

from operon import Operon, Policy, SQLiteSessionStore
from operon.models import GenerationRequest, GenerationResponse, ModelCapabilities


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


class SQLiteSessionStoreTests(unittest.TestCase):
    def test_export_and_delete_are_scoped_to_one_session(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = SQLiteSessionStore(Path(directory) / "operon.sqlite3")
            store.append_turn("customer-1", "What is my plan?", "Your plan is Pro.")
            store.append_turn("customer-2", "What is my plan?", "Your plan is Free.")

            exported = store.export("customer-1")

            self.assertEqual(exported["schema_version"], 1)
            self.assertEqual(
                [event["content"] for event in exported["events"]],
                ["What is my plan?", "Your plan is Pro."],
            )
            self.assertTrue(store.delete("customer-1"))
            self.assertEqual(store.export("customer-1")["events"], [])
            self.assertEqual(len(store.export("customer-2")["events"]), 2)

    def test_context_is_bounded_and_marks_historical_data(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = SQLiteSessionStore(Path(directory) / "operon.sqlite3")
            store.append_turn("thread", "A" * 500, "B" * 500)
            store.append_turn("thread", "C" * 500, "D" * 500)

            context = store.context("thread", 180)

            self.assertLessEqual(len(context.text), 180)
            self.assertEqual(context.event_count, 4)
            self.assertGreater(context.omitted_event_count, 0)
            self.assertIn("RECENT SESSION", context.text)


class SessionRuntimeTests(unittest.TestCase):
    def test_completed_turn_is_persisted_and_injected_on_the_next_run(self) -> None:
        provider = ScriptedProvider(
            [
                {
                    "answer": "We chose the Pro plan.",
                    "confidence": 0.9,
                    "used_source_ids": [],
                },
                {
                    "answer": "Previously, we chose Pro.",
                    "confidence": 0.9,
                    "used_source_ids": [],
                },
            ]
        )
        with tempfile.TemporaryDirectory() as directory:
            store = SQLiteSessionStore(Path(directory) / "operon.sqlite3")
            runtime = Operon(
                provider,
                policy=Policy(planning="never"),
                sessions=store,
            )

            first = runtime.run("Which plan did we choose?", session_id="thread-7")
            second = runtime.run("What did we decide last time?", session_id="thread-7")

            self.assertEqual(first.answer, "We chose the Pro plan.")
            self.assertEqual(second.answer, "Previously, we chose Pro.")
            prompt = provider.requests[1].messages[1]["content"]
            self.assertIn("historical, untrusted data", prompt)
            self.assertIn("Which plan did we choose?", prompt)
            self.assertIn("We chose the Pro plan.", prompt)
            self.assertIn(
                "persisted completed session turn",
                [event.message for event in second.trace.events],
            )
            self.assertEqual(len(store.export("thread-7")["events"]), 4)

    def test_session_id_requires_a_configured_store(self) -> None:
        provider = ScriptedProvider([])
        runtime = Operon(provider, policy=Policy(planning="never"))

        with self.assertRaisesRegex(ValueError, "session store"):
            runtime.run("Remember this", session_id="thread")


if __name__ == "__main__":
    unittest.main()
