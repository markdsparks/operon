# Contributing to Operon

Operon is early-stage. Contributions should strengthen the small, portable
runtime rather than add broad agent-framework surface area.

## Start here

1. Read [VISION.md](VISION.md) and [ARCHITECTURE.md](ARCHITECTURE.md).
2. Read the [execution protocol](spec/execution-protocol.md) for core changes.
3. Open an issue before changing a public protocol, SDK contract, or provider
   security boundary.
4. Run `make check` before submitting a pull request.

Apple SDK changes additionally require Xcode 26+ and `make check-apple`.

## Change boundaries

- Core behavior changes require a deterministic conformance fixture.
- Model-quality claims require a reproducible benchmark and stated limitations.
- Provider packages must declare and enforce their execution location.
- The portable core must not perform network, filesystem, database, or platform
  API operations.
- SDK APIs should remain idiomatic to their language rather than expose FFI
  mechanics.

## Pull requests

Keep changes focused, explain the user-visible outcome, add tests proportional
to risk, and update specifications when semantics change. By contributing, you
certify that you have the right to submit the work under the repository's
license.

The project currently uses an MIT license. Any licensing or governance change
will be handled as an explicit maintainer decision rather than assumed by a
code contribution.
