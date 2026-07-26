# Operon v0.4.0 — Complete native streams and inspectable abstention

Operon v0.4 closes three failures that surfaced in real Apple integrations:
guided-generation schemas could collide, a streamed turn could finish without
delivering its result, and a safe refusal could hide the evidence it considered.

## Install it

The repository root is a Swift package backed by a canonical, checksummed Apple
XCFramework release asset:

```swift
.package(url: "https://github.com/markdsparks/operon.git", from: "0.4.0")
```

The core driver, SQLite grounding, and memory support iOS 16+ and macOS 13+.
Apple Foundation Models stays isolated in its own iOS 26+/macOS 26+ product.

## Apple guided generation handles real application schemas

Every inlined object in an Apple Foundation Models generation schema now gets a
collision-free, deterministic identifier. This fixes schemas with repeated
property names or `$defs` reached through multiple paths—the shape common in
application extraction contracts.

In the focused integration reproduction that exposed the bug, the same
82-document corpus moved from zero successful guided generations in three runs
to three in three runs after the fix. That is a development reproduction, not a
general model benchmark; the permanent schema tests enforce the underlying
identifier invariant.

## A Swift stream finishes with the authoritative result

The terminal stream event now carries `OperonStreamCompletion`, including the
status and complete portable result envelope. Apps no longer need to treat a
successful stream as progress-only or run the turn again to obtain its result.

```swift
for try await event in driver.stream(query) {
  if case .finished(let completion) = event {
    let terminal = OperonCoreCompletedResult(json: completion.json)
    render(terminal.json)
  }
}
```

This is a source-breaking Swift API change: switch statements that matched
`.finished(let status)` must now accept an `OperonStreamCompletion` value.

## A safe refusal shows what it considered

Structured abstentions now retain the retrieved sources that were available to
the model. A host can distinguish “retrieval found nothing” from “sources were
found but did not support this claim,” show the considered evidence, and improve
the corpus without turning abstention into an opaque error.

## Compatibility

- Package and public API version: **0.4.0**
- Execution protocol: **experimental 0.3**
- C ABI: **experimental 0.3**
- Snapshot format: **version 2**

There is no wire-protocol, ABI, or snapshot migration in this release. Swift
stream consumers need the source update described above.

## Validation

The release passes 19 Rust unit tests, 8 protocol conformance tests, 54 Python
tests, 8 JavaScript tests, the real WASM smoke test, 14 Swift tests, the Apple
Foundation Models iOS build, and every Apple XCFramework slice/link check. The
published tag is also installed by a clean external SwiftPM consumer.

Historical GroundBench and AppBench evidence is unchanged; v0.4 does not
relabel existing measurements as new model results.
