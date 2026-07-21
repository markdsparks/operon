from __future__ import annotations

import json
import tempfile
import unittest
from collections import deque
from pathlib import Path

from operon import (
    MemoryAuthority,
    MemoryKind,
    MemoryRecord,
    MemoryScope,
    MemorySensitivity,
    Operon,
    Policy,
    SQLiteMemoryStore,
)
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


class SQLiteMemoryStoreTests(unittest.TestCase):
    def test_scope_filters_precede_retrieval_and_expired_records_are_excluded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = SQLiteMemoryStore(Path(directory) / "operon.sqlite3")
            store.put(
                MemoryRecord.create(
                    namespace="user-a",
                    subject="customer-1",
                    kind=MemoryKind.PREFERENCE,
                    content="Customer prefers concise plan updates.",
                    authority=MemoryAuthority.USER_CONFIRMED,
                )
            )
            store.put(
                MemoryRecord.create(
                    namespace="user-b",
                    subject="customer-1",
                    kind=MemoryKind.PREFERENCE,
                    content="Customer prefers verbose plan updates.",
                    authority=MemoryAuthority.USER_CONFIRMED,
                )
            )
            store.put(
                MemoryRecord.create(
                    namespace="user-a",
                    subject="customer-1",
                    kind=MemoryKind.FACT,
                    content="The expired plan was Basic.",
                    authority=MemoryAuthority.APPLICATION_VERIFIED,
                    valid_until="2000-01-01T00:00:00+00:00",
                )
            )

            records = store.search(
                "What plan update does the customer prefer?",
                MemoryScope(namespace="user-a", subject="customer-1"),
                limit=5,
            )

            self.assertEqual(len(records), 1)
            self.assertIn("concise", records[0].content)

    def test_supersession_tombstone_export_and_namespace_delete(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = SQLiteMemoryStore(Path(directory) / "operon.sqlite3")
            old = store.put(
                MemoryRecord.create(
                    namespace="user-a",
                    kind=MemoryKind.DECISION,
                    content="The customer selected the Free plan.",
                    authority=MemoryAuthority.APPLICATION_VERIFIED,
                )
            )
            current = store.put(
                MemoryRecord.create(
                    namespace="user-a",
                    kind=MemoryKind.DECISION,
                    content="The customer selected the Pro plan.",
                    authority=MemoryAuthority.APPLICATION_VERIFIED,
                    supersedes=old.id,
                )
            )

            records = store.search(
                "Which plan did the customer select?",
                MemoryScope(namespace="user-a"),
                limit=5,
            )
            exported = store.export(MemoryScope(namespace="user-a"))

            self.assertEqual([record.id for record in records], [current.id])
            self.assertTrue(store.tombstone(current.id))
            self.assertEqual(
                store.search("selected plan", MemoryScope(namespace="user-a"), 5), ()
            )
            statuses = {record["id"]: record["status"] for record in exported["records"]}
            self.assertEqual(statuses[old.id], "superseded")
            self.assertEqual(statuses[current.id], "active")
            self.assertEqual(store.delete_namespace("user-a"), 2)

    def test_sensitivity_filter_applies_before_search(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = SQLiteMemoryStore(Path(directory) / "operon.sqlite3")
            store.put(
                MemoryRecord.create(
                    namespace="user-a",
                    kind=MemoryKind.FACT,
                    content="The private renewal date is Friday.",
                    authority=MemoryAuthority.APPLICATION_VERIFIED,
                )
            )
            store.put(
                MemoryRecord.create(
                    namespace="user-a",
                    kind=MemoryKind.FACT,
                    content="The public renewal announcement is Friday.",
                    authority=MemoryAuthority.APPLICATION_VERIFIED,
                    sensitivity=MemorySensitivity.PUBLIC,
                )
            )

            records = store.search(
                "renewal Friday",
                MemoryScope(
                    namespace="user-a",
                    allowed_sensitivities=(MemorySensitivity.PUBLIC,),
                ),
                limit=5,
            )

            self.assertEqual(len(records), 1)
            self.assertEqual(records[0].sensitivity, MemorySensitivity.PUBLIC)


class MemoryRuntimeTests(unittest.TestCase):
    def test_app_authorized_memory_is_injected_but_not_mutated_by_the_model(self) -> None:
        provider = ScriptedProvider(
            [
                {
                    "answer": "The customer prefers concise updates.",
                    "confidence": 0.9,
                    "used_source_ids": [],
                }
            ]
        )
        with tempfile.TemporaryDirectory() as directory:
            store = SQLiteMemoryStore(Path(directory) / "operon.sqlite3")
            record = store.put(
                MemoryRecord.create(
                    namespace="user-a",
                    kind=MemoryKind.PREFERENCE,
                    content="Customer prefers concise updates.",
                    authority=MemoryAuthority.USER_CONFIRMED,
                )
            )
            runtime = Operon(
                provider,
                policy=Policy(planning="never"),
                memory=store,
            )

            response = runtime.run(
                "How should I update this customer?",
                memory_scope=MemoryScope(namespace="user-a"),
            )

            prompt = provider.requests[0].messages[1]["content"]
            self.assertIn("DURABLE MEMORY", prompt)
            self.assertIn(record.id, prompt)
            self.assertIn("application-selected historical data", prompt)
            self.assertIn(
                "retrieved authorized durable memory",
                [event.message for event in response.trace.events],
            )
            self.assertEqual(
                len(store.export(MemoryScope(namespace="user-a"))["records"]), 1
            )

    def test_memory_scope_requires_a_configured_store(self) -> None:
        runtime = Operon(ScriptedProvider([]), policy=Policy(planning="never"))

        with self.assertRaisesRegex(ValueError, "memory store"):
            runtime.run("What do you know?", memory_scope=MemoryScope(namespace="user-a"))


if __name__ == "__main__":
    unittest.main()
