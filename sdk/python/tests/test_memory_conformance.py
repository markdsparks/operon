from __future__ import annotations

import json
import tempfile
import unittest
from collections import deque
from pathlib import Path
from typing import Any

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
    def __init__(self) -> None:
        self.responses = deque(
            [
                json.dumps(
                    {
                        "answer": "I found the requested memory.",
                        "confidence": 0.9,
                        "used_source_ids": [],
                    }
                )
            ]
        )
        self.requests: list[GenerationRequest] = []

    @property
    def capabilities(self) -> ModelCapabilities:
        return ModelCapabilities(structured_output=True, privacy="local")

    def generate(self, request: GenerationRequest) -> GenerationResponse:
        self.requests.append(request)
        return GenerationResponse(self.responses.popleft())


class MemoryConformanceTests(unittest.TestCase):
    def test_memory_lifecycle_fixtures(self) -> None:
        root = Path(__file__).parents[3] / "conformance" / "memory"
        fixtures = sorted(root.glob("*.json"))
        self.assertGreaterEqual(len(fixtures), 4)
        for path in fixtures:
            with self.subTest(fixture=path.name), tempfile.TemporaryDirectory() as directory:
                fixture = json.loads(path.read_text(encoding="utf-8"))
                store = SQLiteMemoryStore(Path(directory) / "operon.sqlite3")
                for operation in fixture["operations"]:
                    if operation["op"] == "put":
                        store.put(_record(operation["record"]))
                    elif operation["op"] == "tombstone":
                        self.assertTrue(store.tombstone(operation["id"]))
                    else:
                        self.fail(f"unknown memory fixture operation: {operation['op']}")

                for search in fixture["searches"]:
                    scope = _scope(search["scope"])
                    records = store.search(search["query"], scope, limit=5)
                    self.assertEqual(
                        [record.id for record in records],
                        search["expected_ids"],
                        fixture["name"],
                    )
                    if search.get("requires_untrusted_prompt_marker"):
                        provider = ScriptedProvider()
                        runtime = Operon(
                            provider,
                            policy=Policy(planning="never"),
                            memory=store,
                        )
                        runtime.run(search["query"], memory_scope=scope)
                        system = provider.requests[0].messages[0]["content"].lower()
                        prompt = provider.requests[0].messages[1]["content"].lower()
                        self.assertIn("durable memory", system)
                        self.assertIn("untrusted data", system)
                        self.assertIn("application-selected historical data", prompt)


def _record(data: dict[str, Any]) -> MemoryRecord:
    return MemoryRecord(
        id=data["id"],
        namespace=data["namespace"],
        subject=data.get("subject"),
        kind=MemoryKind(data["kind"]),
        content=data["content"],
        authority=MemoryAuthority(data["authority"]),
        sensitivity=MemorySensitivity(data.get("sensitivity", "private")),
        valid_until=data.get("valid_until"),
        supersedes=data.get("supersedes"),
    )


def _scope(data: dict[str, Any]) -> MemoryScope:
    return MemoryScope(
        namespace=data["namespace"],
        subject=data.get("subject"),
        allowed_sensitivities=tuple(
            MemorySensitivity(value)
            for value in data.get("allowed_sensitivities", ["private", "internal"])
        ),
    )


if __name__ == "__main__":
    unittest.main()
