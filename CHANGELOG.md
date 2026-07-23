# Changelog

All notable changes to Operon are documented here. The project follows semantic
versioning while its public APIs remain alpha.

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
