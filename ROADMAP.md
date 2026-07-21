# Roadmap

## Milestone 0: executable hypothesis

- [x] Model capability and generation contracts
- [x] OpenAI-compatible local provider
- [x] Adaptive planning and simple-query fast path
- [x] Local text grounding with a context budget
- [x] Structured answer validation and bounded repair
- [x] Privacy-aware provider admission
- [x] Inspectable execution traces
- [x] Dependency-free tests and CLI
- [x] Add a repeatable direct-versus-Operon benchmark harness
- [x] Add initial human-labeled grounded decision cases
- [x] Expand to at least 30 deterministic development cases
- [x] Run a staged 1.5B–8B smoke matrix
- [ ] Human-review the 30-case corpus and run the full matrix with repetitions

Exit criterion: Operon demonstrates a repeatable quality improvement on at
least three task classes while reporting its latency and generation overhead.

## Milestone 1: useful desktop package

- Embedded llama.cpp provider and GGUF model management
- Hybrid lexical/vector retrieval and incremental indexing
- [x] Portable typed application output schema subset
- Tool registration and constrained tool selection
- Token-aware context compression
- Streaming, cancellation, and execution deadlines
- Python wheels and a standalone CLI for macOS and Linux

## Milestone 2: portable native core

- [x] Extract the validated state machine and contracts into Rust
- [x] Keep scheduling outside the core's public contract
- [x] Port policy, planning, grounding, validation, repair, and trace behavior
- [x] Provide an experimental C ABI for opaque session handles and JSON commands/events
- [ ] Stabilize the C ABI and add native Swift/Python bindings
- [ ] Bind the Python SDK to `operon-core`
- [ ] Add model, memory, latency, and energy accounting
- [x] Add a versioned command/event protocol and replayable conformance format
- [x] Make the synchronous runtime drive the resumable core
- [ ] Stabilize safe trace serialization and session snapshots
- [x] Research local session and durable-memory architecture
- [x] Add local SQLite session persistence and bounded historical context to the Python reference host
- [x] Define an experimental host-owned durable-memory search command and typed record envelope
- [x] Add application-authorized SQLite/FTS5 durable-memory retrieval to the Python reference host
- [x] Add scope, deletion, temporal-update, and untrusted-memory conformance fixtures
- [x] Drive scoped durable-memory context through the shared core and Apple host
- [ ] Add durable session-context injection through the shared core and Apple host

## Milestone 3: Apple native

- [x] Swift package for iOS and macOS
- [x] Apple Foundation Models system-model provider
- [x] Grounded typed-output vertical slice with validation and bounded repair
- Embedded llama.cpp provider
- Optional MLX provider
- Keychain-aware secrets and sandboxed document access
- Background, thermal, and low-power execution policies

## Milestone 4: Android native

- Kotlin SDK and coroutine integration
- Embedded llama.cpp baseline
- ExecuTorch and system Gemini Nano providers
- Android hardware capability and energy policies

## Guardrails

- No visual graph builder before the wrap-and-run experience is excellent.
- No provider-specific behavior in the cognitive runtime.
- No cloud execution without an explicit application policy.
- No capability claim without a direct-vs-Operon benchmark.
