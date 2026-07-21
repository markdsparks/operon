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
