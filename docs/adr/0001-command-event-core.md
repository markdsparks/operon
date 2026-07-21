# ADR 0001: Command/event portable core

- Status: accepted
- Date: 2026-07-21

## Context

Operon's first Rust runtime calls synchronous inference and grounding traits.
That works for tests and command-line providers, but it is a poor boundary for
Swift concurrency, Apple Foundation Models, Kotlin coroutines, cancellation,
and platform lifecycle management.

## Decision

The canonical core is a resumable state machine. It yields typed commands and
accepts matching typed events. Platform SDKs perform all asynchronous and
side-effecting work. The synchronous API remains a compatibility adapter rather
than the portable architecture.

## Consequences

- Native SDKs retain idiomatic concurrency and cancellation.
- Executions can be recorded and replayed as conformance fixtures.
- The core has no ambient network or storage authority.
- Protocol types become public compatibility commitments.
- Host adapters must handle the command loop and provider capability checks.

