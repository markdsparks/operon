# Architecture

Operon separates cognition policy from model execution and platform services.

```text
Application
   ↓
Python / Swift / Kotlin SDK
   ↓
Operon Core
   ├── classifier and planner
   ├── context budgeter
   ├── grounding, memory, and skill ports
   ├── policy and routing
   ├── validators and repair
   └── execution trace
   ↓
InferenceProvider
   ├── OpenAI-compatible local server
   ├── llama.cpp
   ├── MLX / Core ML
   ├── ExecuTorch / LiteRT
   └── explicitly authorized cloud model
```

## Current execution lifecycle

1. Validate the request and local-only policy.
2. Take a simple-query fast path or ask the model for a typed plan.
3. Run any model-requested, application-registered skills through the host.
4. Retrieve local context using the query, intent, and subquestions.
5. Fit skill results and ranked source chunks into the configured context budget.
6. Generate a structured answer following the plan.
7. Validate answer shape, confidence, provenance, and inline citations.
8. Run a targeted repair up to the configured limit.
9. Return the answer and an execution trace.

## Stable boundaries

`InferenceProvider` accepts a `GenerationRequest`, reports
`ModelCapabilities`, and returns a `GenerationResponse`. It intentionally knows
nothing about retrieval, planning, or verification.

Each generation request carries a reasoning-effort hint. The v0 runtime disables
provider-native thinking for bounded structured stages because a thinking model
can consume its output budget before emitting JSON. Future policies may allocate
different reasoning budgets by task, hardware state, and validation history.

Grounding returns ranked `Source` objects with stable IDs and provenance. The
current implementation is lexical; vector and hybrid indexes can implement the
same behavior later.

Skills are portable capability descriptors with an ID, description, input
schema, output schema, and an optional user-confirmation requirement. The core
can request an `InvokeSkill` command only for a descriptor configured by the
application. The host performs the call, and the core validates the returned
value before it becomes attributable answer context. This keeps permissions,
side effects, device APIs, and business logic in the app.

`Policy` holds explicit execution constraints. Platform hosts will eventually
extend this with energy state, thermal state, foreground/background execution,
network availability, and cloud consent.

## Portable core

`crates/operon-core` is the portable Rust implementation of the execution state
machine. It owns policy admission, adaptive planning, grounding orchestration,
context budgeting, structured generation, provenance validation, bounded
repair, and trace semantics.

The dependency-free Python SDK remains the behavioral reference while the FFI
boundary is built. The developer-preview Swift package is already executable
against Apple Foundation Models and establishes the native app-facing API.
Python, Swift, and Kotlin SDKs own language-native ergonomics while core
behavior remains identical across platforms.

The canonical core is a resumable command/event state machine. It yields
`Generate`, `Retrieve`, `SearchMemory`, `InvokeSkill`, and validation commands,
then accepts matching completion events.
Native SDKs perform those operations using Python asyncio, Swift concurrency,
or Kotlin coroutines; the core imposes no async runtime and has no ambient
network or storage authority.

`OperonRuntime::run` is the synchronous compatibility host. It drives the same
resumable session through the existing provider traits, so command-line users
retain a simple blocking API without creating a second execution path.

The first experimental portability boundary is a narrow C ABI using opaque
session handles and serialized commands/events. Provider work remains host-owned
so Operon can wrap Apple Foundation Models, llama.cpp, MLX, ExecuTorch, system
models, and HTTP adapters without linking them into the core. See the
[C ABI guide](docs/ffi/c-abi.md).

Until that ABI lands, the Swift vertical slice duplicates the minimum
orchestration transitions needed to validate the platform design. This is a
deliberate migration seam, not a second canonical core: the public Swift API and
Apple provider stay in place while its internal driver moves to Rust.

Deterministic application logic remains outside the model. Calculations,
permissions, side effects, and hard business invariants are performed or
validated by app code; their results may be supplied to the model as
authoritative grounding so it can classify, synthesize, and explain them.

See [spec/execution-protocol.md](spec/execution-protocol.md) and
[ADR 0001](docs/adr/0001-command-event-core.md) and
[ADR 0002](docs/adr/0002-deterministic-app-authority.md).

The recommended session and durable-memory architecture is documented in
[local context and memory research](docs/research/local-memory-architecture.md).

The protocol emits a host-owned `SearchMemory` command whenever a session is
configured with an authorized memory scope. The Python reference host implements
application-authored SQLite/FTS5 records; the model never receives write access.

`operon-core` now contains the first shared context compiler. It applies a
portable character budget across session text, memory records, and sources; the
current core runtime uses it for source packing, while the C ABI will let Python,
Swift, and Kotlin use the complete same compilation path.
