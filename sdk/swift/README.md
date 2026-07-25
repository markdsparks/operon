# Operon Swift SDK

Operon's Swift products drive the canonical Rust execution core while the app
retains model, storage, permission, and side-effect authority.

## Add the package

Add the repository root in Xcode or `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/markdsparks/operon.git", from: "0.3.0")
]
```

Choose only the products the app needs:

```swift
.product(name: "OperonCoreDriver", package: "operon"),
.product(name: "OperonSQLite", package: "operon"),
.product(name: "OperonFoundationModels", package: "operon"),
```

`OperonKit`, `OperonCoreFFI`, `OperonCoreDriver`, and `OperonSQLite` support
iOS 16+ and macOS 13+. `OperonFoundationModels` requires iOS 26+ or macOS 26+
and Xcode 26; it no longer raises the deployment target of apps using another
provider. The binary core is downloaded as a checksummed XCFramework release
asset.

## Run with Apple Foundation Models

```swift
import OperonCoreDriver
import OperonFoundationModels

@available(iOS 26, macOS 26, *)
func ask(_ query: String) async throws {
  let driver = OperonCoreDriver(
    model: AppleFoundationModelsProvider(),
    policy: OperonPolicy(planning: .adaptive)
  )

  let terminal = try await driver.run(query)
  print(terminal.json)
}
```

The provider uses Apple guided-generation schemas. Operon supports objects,
arrays, numeric and array bounds, enums, local `$defs`/`$ref` definitions, and
post-generation application validation. Bounds are forwarded into Apple
generation guides where the framework supports them and checked again by the
core.

## Local grounding and memory

`OperonSQLite` is a dependency-free Apple adapter backed by system SQLite3 and
FTS5. Grounding indexes only new or changed documents; durable memory filters
namespace, subject, sensitivity, validity, and status before BM25 ranking.

```swift
import OperonSQLite

let storeURL = appSupport.appending(path: "operon.sqlite3")
let grounding = try SQLiteOperonGroundingProvider(url: storeURL)
try await grounding.index([
  OperonDocument(id: "policy", path: "policy.md", text: policyText)
])

let memory = try SQLiteOperonMemoryStore(url: storeURL)
let driver = OperonCoreDriver(
  model: model,
  grounding: grounding,
  memory: memory,
  memoryScope: OperonMemoryScope(namespace: "account-42"),
  policy: OperonPolicy(groundingMode: .extractive)
)
```

The app owns memory writes, supersession, tombstones, export, and deletion.
The model receives only records selected by the declared scope.

## Skills and typed session state

Implement `OperonSessionArtifactProvider` and `OperonSkillHost` to make the
complete 0.3 protocol available in an app. Operon loads bounded typed artifacts
before planning, asks the host to prepare partial calls, validates completed
arguments, invokes only registered skills, and returns receipts. Preparation
returns `ready`, `needsInput`, `rejected`, or `unavailable`; missing input
becomes a typed clarification instead of generic prose.

The model interprets language and semantic references. App code resolves IDs,
dates, permissions, calculations, UI targets, and every side effect.

## Streaming, cancellation, and measurement

`stream(_:)` returns `AsyncThrowingStream<OperonRunEvent, Error>`. Provisional
model output is explicitly non-authoritative; only `.finished` follows core
validation. Cancelling the consuming task cancels active provider work and
produces a terminal cancellation outcome.

The stream also emits `OperonPerformanceSample` values for each model call and
the full run. Samples include elapsed time, token counts when the provider
reports them, thermal state, and low-power state. These let an app collect real
device measurements; the repository does not yet publish iPhone performance.

```swift
for try await event in driver.stream("Summarize the local policy") {
  switch event {
  case .provisionalModelOutput(_, let text): renderDraft(text)
  case .measurement(let sample): metrics.record(sample)
  case .finished(let completion):
    let result = OperonCoreCompletedResult(json: completion.json)
    renderTerminal(completion.status, result)
  default: break
  }
}
```

## Terminal outcomes

Typed runs return `OperonRunOutcome<Output>`:

- `.completed` with validated output, sources, claims, and trace;
- `.clarification` with missing fields and skill identity;
- `.abstained` when sources or validation cannot support a result; or
- `.cancelled` when the host or caller stops the turn.

Extractive mode verifies every evidence quote as an exact substring of the
canonical retrieved chunk and derives byte offsets. This proves where text came
from, not that every paraphrase is semantically entailed.

## Snapshots and recovery

`OperonCoreSession.snapshotJSON()` captures versioned private state at a command
boundary, and `OperonCoreSession(snapshotJSON:)` restores it without replaying
completed work. Persist the outstanding command beside the snapshot. Use each
skill command's stable idempotency key to deduplicate a redelivered side effect.

## Repository development

The nested manifest uses the locally generated XCFramework:

```bash
make build-apple-xcframework
make verify-apple-xcframework
make test-swift
make build-swift-ios
make lint-swift
```

`scripts/package-apple-xcframework.sh` produces the deterministic release ZIP
and SwiftPM checksum. Tagged releases run the same build and verification in
GitHub Actions.
