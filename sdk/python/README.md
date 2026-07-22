# Operon Python SDK

The Python SDK is the executable reference host for Operon. It currently
contains a dependency-free local document retriever, an OpenAI-compatible
provider, the `operon` CLI, and the original orchestration implementation used
for real-model experiments.

Install it from the repository root:

```bash
python3 -m pip install -e sdk/python
```

Run its tests without installation:

```bash
PYTHONPATH=sdk/python/src python3 -m unittest discover -s sdk/python/tests -v
```

The SDK will move onto the Rust command/event core after the protocol and C ABI
stabilize. Until then, shared conformance fixtures prevent semantic drift.

## Local session continuity

`SQLiteSessionStore` persists completed user/assistant turns locally and inserts
a bounded, explicitly marked historical context block on a later call. It does
not write inferred long-term facts.

```python
from operon import Operon, SQLiteSessionStore

assistant = Operon.wrap(
    provider,
    sessions=SQLiteSessionStore("./operon.sqlite3"),
)

assistant.run("We chose the Pro plan.", session_id="customer-123")
result = assistant.run("What did we decide last time?", session_id="customer-123")

# Apps can provide privacy controls around these explicit operations.
exported = assistant.sessions.export("customer-123")
assistant.sessions.delete("customer-123")
```

Historical session data is treated as untrusted context and is never promoted to
durable semantic memory automatically. See the
[local memory architecture](../../docs/research/local-memory-architecture.md)
for the staged design.

## Typed durable memory

Applications may add approved facts, preferences, decisions, and episodes to a
local SQLite/FTS5 store. A required `MemoryScope` filters namespace, optional
subject, sensitivity, validity, and record status before lexical ranking.

```python
from operon import (
    MemoryAuthority, MemoryKind, MemoryRecord, MemoryScope, SQLiteMemoryStore,
)

memory = SQLiteMemoryStore("./operon.sqlite3")
memory.put(MemoryRecord.create(
    namespace="customer-123",
    kind=MemoryKind.PREFERENCE,
    content="Customer prefers concise updates.",
    authority=MemoryAuthority.USER_CONFIRMED,
))

assistant = Operon.wrap(provider, memory=memory)
result = assistant.run(
    "How should I update this customer?",
    memory_scope=MemoryScope(namespace="customer-123"),
)
```

The app controls writes, supersession, tombstones, export, and deletion. The
model has read-only, attributed access to the selected historical records.

## App-owned skills

Skills connect the plan to fresh app state or controlled actions without giving
the model ambient authority. Register a finite typed catalog; only its entries
can be requested. The host validates inputs and outputs, and may require an
explicit user confirmation before a handler runs.

```python
from operon import Skill, SkillDescriptor, SkillRegistry, SkillResult

skills = SkillRegistry([
    Skill(
        SkillDescriptor(
            id="calendar.availability",
            description="Read the application's calendar snapshot.",
            input_schema={"type": "object", "properties": {"day": {"type": "string"}},
                          "required": ["day"], "additionalProperties": False},
            output_schema={"type": "object", "properties": {"open": {"type": "boolean"}},
                           "required": ["open"], "additionalProperties": False},
        ),
        lambda arguments: SkillResult({"open": lookup_day(arguments["day"])}),
    )
])

assistant = Operon.wrap(provider, skills=skills)
```

Skill results are validated and become citable local context. The application,
not the model, owns the handler, permission prompt, and every side effect.
