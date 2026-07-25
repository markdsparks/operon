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
- [x] Typed skill registration and constrained capability selection
- Token-aware context compression
- [x] Streaming, cancellation, and execution deadlines across Swift and browser hosts
- Python wheels and a standalone CLI for macOS and Linux

## Milestone 2: portable native core

- [x] Extract the validated state machine and contracts into Rust
- [x] Keep scheduling outside the core's public contract
- [x] Port policy, planning, grounding, validation, repair, and trace behavior
- [x] Provide an experimental C ABI for opaque session handles and JSON commands/events
- [x] Add a versioned Swift/C binding and distributable Apple XCFramework
- [ ] Stabilize the C ABI and add a native Python binding
- [ ] Bind the Python SDK to `operon-core`
- [x] Add model-call/run latency, token, thermal, and low-power measurement events on Apple
- [ ] Publish real iPhone latency, memory, energy, and thermal measurements
- [x] Add a versioned command/event protocol and replayable conformance format
- [x] Make the synchronous runtime drive the resumable core
- [x] Add versioned session snapshots and restore entry points to Rust, C, and WASM
- [ ] Stabilize snapshot encryption/storage guidance and cross-version migration
- [x] Research local session and durable-memory architecture
- [x] Add local SQLite session persistence and bounded historical context to the Python reference host
- [x] Define an experimental host-owned durable-memory search command and typed record envelope
- [x] Add application-authorized SQLite/FTS5 durable-memory retrieval to the Python reference host
- [x] Add scope, deletion, temporal-update, and untrusted-memory conformance fixtures
- [x] Drive scoped durable-memory context through the shared core and Apple host
- [ ] Add durable session-context injection through the shared core and Apple host
- [x] Add typed capability dependencies, completion contracts, ready-set decoding, and skill receipts
- [x] Add strict extractive evidence contracts, exact quote offsets, and terminal abstention outcomes
- [x] Add GroundBench answerable/unanswerable faithfulness evaluation
- [ ] Add policy-controlled command retries, fallback providers, and compensation hooks

## Milestone 3: Apple native

- [x] Swift package for iOS and macOS
- [x] Root SwiftPM manifest with checksummed release XCFramework
- [x] Split core iOS 16+/macOS 13+ from the iOS 26+/macOS 26+ Foundation Models product
- [x] Apple Foundation Models system-model provider
- [x] Full Swift protocol host for session state, skills, streaming, and cancellation
- [x] Incremental SQLite FTS5 grounding and scoped durable memory
- [x] Grounded typed-output vertical slice with validation and bounded repair
- Embedded llama.cpp provider
- Optional MLX provider
- Keychain-aware secrets and sandboxed document access
- Background, thermal, and low-power admission policies

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
