# Changelog

All notable changes to Operon are documented here. The project follows semantic
versioning while its public APIs remain alpha.

## 0.3.0 — 2026-07-25

### Added

- Root SwiftPM package with a reproducible, checksummed Apple XCFramework release asset.
- Complete Swift host support for session artifacts, skill preparation/invocation,
  streaming, cancellation, clarification, abstention, and cancellation outcomes.
- Incremental SQLite FTS5 grounding and scoped durable memory on Apple platforms.
- Strict extractive grounding with claim evidence, exact-substring verification,
  derived byte offsets, canonical citations, and model-selected abstention.
- JSON Schema `minItems`, `maxItems`, and reusable local `$defs`/`$ref` support.
- Browser `AbortSignal`, progress, and provisional-generation callbacks.
- GroundBench answerable/unanswerable faithfulness suite and published Qwen3 4B run.
- Apple latency/token/thermal/low-power performance samples for real-device collection.

### Changed

- Execution protocol is now experimental 0.3 and snapshots are version 2.
- Bounded validation exhaustion abstains by default; legacy error behavior is opt-in.
- Core Apple products support iOS 16+/macOS 13+; Foundation Models remains a
  separate iOS 26+/macOS 26+ product.
- Extractive evidence chunks normalize incidental whitespace before prompt and verification.
- Rust, Python, and JavaScript package versions are now 0.3.0.

### Measured

- In GroundBench's 24-run-per-configuration Qwen3 4B matrix, strict extractive
  Operon made every accepted evidence quote exact (100%, versus 75% raw) and
  completed 75% of supported-answer cases. Safe refusal was 41.7%, explicitly
  documenting that exact attribution is not semantic entailment.

### Known limitations

- The public APIs, C ABI, and protocol remain alpha.
- The first GroundBench result uses one local model on an Apple Silicon desktop,
  not a physical iPhone.
- Semantic claim support and safe refusal remain measured gaps after quote verification.
- The Python SDK is still a behavioral reference rather than a Rust-core binding.

## 0.2.0 — 2026-07-23

### Added

- TaskGraph execution compiled from skill `consumes`/`produces` declarations.
- App-owned `CompletionContract` requirements for skill IDs and artifact kinds.
- Ready-set constrained structured decoding for initial planning and replanning.
- Ordered `SkillReceipt` values and stable invocation idempotency keys.
- Versioned Rust execution snapshots with C ABI and WASM restore entry points.
- Browser-driver checkpoint and restore support.
- AppBench 0.2 three-way comparison: raw, linear Operon, and TaskGraph Operon.

### Changed

- Skill results now validate every promised produced artifact kind.
- Replanning rejects actions outside the graph's current ready set.
- Command/event schemas now cover session loading, preparation, invocation, and
  their completion events.
- Rust, Python, and JavaScript package versions are now 0.2.0.

### Measured

- The unchanged four-case dependent-chain workload completed 12 of 12 repeated
  runs with Qwen3 4B and Operon v0.2, versus 6 of 12 with linear Operon
  replanning and 0 of 12 in the raw full-state loop.

### Known limitations

- The APIs, C ABI, and protocol remain experimental.
- Command failures are terminal; policy-controlled retries and compensation are
  planned separately from snapshot redelivery.
- The Python SDK remains a behavioral reference implementation rather than a
  binding to the Rust core.
- The focused v0.2 benchmark isolates dependent chains on one local model; it
  is not a general capability ranking.
