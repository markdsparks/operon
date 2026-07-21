# Operon SDKs

SDKs expose idiomatic platform APIs while implementing the shared execution
protocol and conformance suite.

- `python`: working reference SDK and CLI
- `swift`: developer-preview native SDK with an Apple Foundation Models provider
- `kotlin`: planned after the Apple vertical slice

Platform SDKs own concurrency, cancellation, model APIs, storage, and platform
services. The Swift vertical slice temporarily mirrors a minimal execution path
to validate its API; the C-ABI driver will replace that path with the canonical
Rust command/event core.
