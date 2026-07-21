# Research: local context and memory architecture

- Status: recommended direction
- Date: 2026-07-21
- Scope: local-first memory for small models on mobile and desktop

## Executive conclusion

Operon should become a full local intelligence harness with persistent context,
but it should not implement memory as an unstructured transcript plus vector
search. The recommended architecture has four distinct layers:

1. **Session state**: an append-only record and resumable checkpoint for one
   conversation or workflow.
2. **Working context**: a bounded, per-request compilation of recent turns,
   retrieved memories, grounding, tool results, and instructions.
3. **Durable memory**: typed facts, preferences, decisions, and episodes with
   provenance, authority, time, scope, and lifecycle metadata.
4. **Application knowledge**: documents and structured records owned by the app,
   retrieved through the existing grounding boundary rather than copied into
   conversational memory.

The model may propose memories, but policy and application code decide what is
committed. Retrieval must apply authorization filters before relevance ranking.
Every injected memory must remain attributable in the execution trace.

This design extends Operon's existing strengths—bounded context, grounding,
validation, and resumable execution—without turning it into a general database
or a self-modifying agent framework.

## What the research says

### Memory is a runtime responsibility

Language models are stateless. The CoALA architecture separates working memory
from episodic, semantic, and procedural long-term memory and treats retrieval
and learning as explicit agent actions. That maps closely to Operon's current
command/event core. [CoALA](https://arxiv.org/abs/2309.02427)

MemGPT demonstrates the useful operating-system analogy: a runtime moves
information between bounded in-context memory and larger external memory rather
than expecting the model context window to be the database.
[MemGPT](https://arxiv.org/abs/2310.08560)

Current frameworks independently converge on thread-scoped checkpoints plus
separately namespaced long-term memory. LangGraph distinguishes short-term
thread state from cross-session stores, while Letta distinguishes always-visible
memory blocks from retrieved archival memory.
[LangGraph memory](https://docs.langchain.com/oss/python/concepts/memory),
[Letta context hierarchy](https://docs.letta.com/guides/core-concepts/memory/context-hierarchy)

**Implication for Operon:** session persistence and long-term memory need
different contracts, even if both use one physical database.

### More history is not the same as better context

LongMemEval measures extraction, multi-session reasoning, temporal reasoning,
knowledge updates, and abstention. Its results show that directly supplying long
histories can perform substantially worse than retrieving the right history,
especially for small models. It also finds that indexing expanded keys with
extracted user facts improves retrieval and that dense retrieval generally
outperforms BM25 in its tested settings.
[LongMemEval paper](https://proceedings.iclr.cc/paper_files/paper/2025/file/d813d324dbf0598bbdc9c8e79740ed01-Paper-Conference.pdf)

Apple's on-device model documentation reinforces the constraint: the system
model has a bounded context, and instructions, prompts, tool definitions,
outputs, and transcript entries all consume it. Apple recommends splitting
larger work into smaller operations.
[Apple Foundation Models context guidance](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)

**Implication for Operon:** context compilation—not storage—is the core product
capability. It needs explicit budgets per category and must be testable without
a live model.

### Durable memory needs types, time, and provenance

Generative Agents retrieves memories using relevance, recency, and importance,
then derives higher-level reflections from events. This is useful evidence for
multi-signal ranking, but free-form reflection must not become trusted truth.
[Generative Agents](https://arxiv.org/abs/2304.03442)

Temporal knowledge-graph work such as Zep highlights a real requirement:
memories change, conflict, and become invalid over time.
[Zep](https://arxiv.org/abs/2501.13956)
Operon does not need a graph database initially, but it does need `occurred_at`,
`valid_from`, `valid_until`, and `supersedes` semantics from the beginning.

**Implication for Operon:** summaries and inferred facts are derived artifacts.
They never overwrite the source event, and current-state views must be
rebuildable.

### Memory is also a persistent attack surface

Recent research demonstrates that malicious content can be stored as memory and
influence later sessions, including content originating in retrieved documents.
Write-time filtering alone does not cover attacks that become harmful only when
multiple records are retrieved together.
[Memory Poisoning Attack and Defense](https://arxiv.org/abs/2601.05504),
[MemPoison](https://arxiv.org/abs/2607.14651),
[Sleeper Memory Poisoning](https://arxiv.org/abs/2605.15338)

**Implication for Operon:** memory content is untrusted data, never instructions.
Operon must enforce policy both when writing and when compiling a specific
request's context. Procedural memory should be application-authored and
read-only by default.

## Recommended architecture

```text
Application
   │
   ├── authoritative records and tools
   │
   ▼
Operon execution session
   ├── SessionStore       raw events + resumable checkpoints
   ├── MemoryWriter       candidates → policy → validation → commit
   ├── MemoryStore        typed, scoped, temporal records
   ├── MemoryRetriever    hard filters → hybrid search → rerank
   └── ContextCompiler    allocate budget → render attributed context
                                   │
                                   ▼
                             local model provider
```

### Portable contracts

The Rust core should define these interfaces while hosts own storage and model
APIs:

- `SessionStore`: create, append, checkpoint, resume, compact, and delete a
  thread.
- `MemoryStore`: put, get, search, supersede, tombstone, export, and delete by
  namespace or subject.
- `EmbeddingProvider`: optional host capability with model/version metadata.
- `MemoryPolicy`: authorizes read/write scope, kinds, retention, sensitivity,
  and whether confirmation is required.
- `ContextCompiler`: deterministic selection and rendering under a token or
  character budget.

Memory search should become a versioned host command in the resumable protocol,
not a database dependency linked into the pure core.

### Memory record

The minimum durable representation should include:

```text
id, namespace, subject, kind, content
source_kind, source_ids, authority, confidence
occurred_at, observed_at, valid_from, valid_until
supersedes, sensitivity, retention, status
search_text, embedding_model, embedding_version
created_by, schema_version
```

Recommended `kind` values for the first version are `fact`, `preference`,
`decision`, and `episode`. Procedures and application documents remain outside
model-writable memory.

`authority` should distinguish at least:

1. application-verified;
2. user-confirmed;
3. directly observed user statement;
4. model-inferred; and
5. imported untrusted content.

Authority is not the same as model confidence. Conflicting records are retained
and linked; a projection decides which one is currently applicable.

## Storage and retrieval recommendation

Use SQLite as the default local store. It is embedded, transactional,
cross-platform, inspectable, and already appropriate for session events and
metadata. FTS5 provides built-in full-text retrieval and BM25 ranking.
[SQLite FTS5](https://www.sqlite.org/fts5.html)
Write-ahead logging can improve reader/writer concurrency, subject to each
platform's lifecycle and checkpoint behavior.
[SQLite WAL](https://www.sqlite.org/wal.html)

Start retrieval with:

1. mandatory namespace, subject, sensitivity, and validity filters;
2. FTS5 lexical candidates;
3. optional dense candidates from a host `EmbeddingProvider`;
4. deterministic rank fusion;
5. authority, temporal applicability, recency, and diversity reranking; and
6. context-budget packing with source attribution.

Apple provides on-device sentence embeddings through `NLEmbedding`, making it a
reasonable optional Apple adapter.
[Apple NLEmbedding](https://developer.apple.com/documentation/naturallanguage/nlembedding)
Do not make its embedding space part of the portable schema: model revisions
must be recorded and reindexing must be supported.

`sqlite-vec` is promising for portable local vector search and publishes mobile
artifacts, but it remains pre-v1 and currently uses exhaustive search. Treat it
as an optional experimental accelerator, not a v0 storage contract.
[sqlite-vec](https://alexgarcia.xyz/sqlite-vec/),
[mobile support](https://alexgarcia.xyz/sqlite-vec/android-ios.html)

## Safe write path

The default path should be conservative:

1. Append the original session event.
2. Let the app write authoritative records directly, or ask the model for typed
   memory candidates.
3. Reject candidates outside allowed kinds and scopes.
4. Preserve source references and classify authority.
5. Detect duplicates, temporal updates, and contradictions.
6. Require app or user confirmation when policy says so.
7. Commit atomically; generate embeddings asynchronously.
8. Trace the decision without exposing sensitive content by default.

Model-proposed writes should initially happen after the response, off the
latency-critical path. Failed extraction must not fail the user's request.

On Apple platforms, protect the database with iOS file data protection and keep
encryption keys or other small secrets in Keychain rather than in memory rows.
[Apple file protection](https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files),
[Keychain Services](https://developer.apple.com/documentation/security/keychain-services)

## Product API direction

The simple path should remain small:

```swift
let assistant = Operon.wrap(
  provider,
  grounding: appKnowledge,
  memory: .local(namespace: userID)
)

let result = try await assistant.run(
  "What did we decide last time?",
  session: conversationID
)
```

Advanced applications can supply policies, custom stores, embeddings, and
confirmation UI. `result.trace` should explain which memories were considered,
selected, excluded by policy, superseded, or dropped for budget—using IDs and
safe metadata rather than raw private content.

Users and applications must be able to inspect, correct, export, and delete
memory. “Forget this” must create an immediate tombstone, remove it from
retrieval, and schedule physical deletion from derived indexes and summaries.

## Staged implementation

### Slice 1: sessions without learned memory

- Append-only SQLite session event store.
- Resume by session ID.
- Recent-turn window plus deterministic summary checkpoint.
- Context budgets and trace events.
- Export/delete tests.

This creates continuity without introducing model-authored durable facts.

### Slice 2: typed durable memory

- Memory record schema, namespaces, authority, time, retention, and tombstones.
- Application-authored writes and FTS5 retrieval.
- Deterministic context compiler.
- Scope-isolation, update, contradiction, deletion, and injection tests.

Initial implementation: the Python reference host now provides the record
envelope, application-authored SQLite/FTS5 writes, namespace/subject/sensitivity
and temporal filtering before search, supersession, tombstones, export, and
namespace deletion. Initial deterministic conformance fixtures now cover scope
isolation, temporal supersession, tombstones, and untrusted retrieved content.
Dense retrieval and retention policies remain future work.

### Slice 3: model-proposed memory

- Guided candidate extraction after a response.
- Write policy and optional confirmation.
- Deduplication and supersession.
- Memory review UI hooks.

### Slice 4: hybrid semantic retrieval

- Pluggable embeddings with versioned indexes.
- Dense/lexical rank fusion and reranking.
- Apple `NLEmbedding` adapter; evaluate a portable embedding model separately.
- Reindexing, storage, latency, memory, and energy accounting.

Graphs, autonomous procedural-memory editing, cross-device sync, and shared
multi-agent memory should wait until the simpler design has measured failures
that justify them.

## Evaluation gate

Do not ship memory based on anecdotal conversations. Add a deterministic
conformance suite and a model benchmark with:

- retrieval recall and NDCG at fixed context budgets;
- answer accuracy for facts, updates, temporal questions, and multi-session
  synthesis;
- correct abstention when no authorized memory supports an answer;
- write precision and contradiction/update handling;
- namespace leakage and deletion failures;
- memory-poisoning success rate;
- p50/p95 latency, database growth, peak memory, tokens, and device energy; and
- comparisons against recent-turn-only and full-transcript baselines.

Use LongMemEval as an external reference, but create smaller Operon fixtures
that exercise local SLMs and mobile resource limits. Benchmark retrieval and
answer generation separately so a weak model is not mistaken for a weak store,
or vice versa.

## Decision

Proceed with Slice 1, but define the typed memory envelope and threat model
before freezing the C ABI. The session store can ship first; automatic durable
memory writes should not.
