# Operon Swift SDK

This developer-preview package contains:

- `OperonKit`: async app-facing orchestration, typed output, grounding, citation
  validation, bounded repair, and safe trace summaries;
- `OperonFoundationModels`: Apple `SystemLanguageModel` provider using runtime
  guided-generation schemas; and
- `OperonExpenseDemo`: an on-device grounded expense decision.

Requirements: Xcode 26+, iOS 26+ or macOS 26+, and an eligible device with Apple
Intelligence enabled.

```bash
swift test --package-path sdk/swift
swift run --package-path sdk/swift OperonExpenseDemo
# From the repository root, including an iOS Simulator compile:
make check-apple
```

The Swift pipeline is an executable vertical slice. The Rust command/event core
remains canonical; the public `OperonKit` API still uses its Swift state
transitions while we preserve that API during migration.

`OperonCoreFFI` is an experimental macOS development bridge to the Rust C ABI.
It owns an opaque core session, returns JSON command envelopes, and accepts JSON
event envelopes from the host. Build the core first with `make build-c-abi`,
then run the bridge test with `make test-swift`. This local target links
`target/release/liboperon_core.dylib`; an iOS distribution must package the
static core library as an XCFramework before using the bridge on device. Build
that artifact with `make build-apple-xcframework`; it produces an ignored
`artifacts/OperonCore.xcframework` containing device arm64 and universal
Simulator slices.

Apps may pass `validateOutput` to enforce deterministic invariants over generated
typed data. This keeps calculations, permissions, and other safety-sensitive
rules in code while letting the model interpret and explain the result.
