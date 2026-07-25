# Operon v0.3.0 — Native, interruptible, and verifiable

Operon v0.3 makes the local harness usable from a real Apple app and gives
grounded answers a stronger, inspectable evidence contract.

## Install it instead of vendoring it

The repository root is now a Swift package. A tagged release ships a
reproducible `OperonCore.xcframework.zip` asset with the checksum committed in
`Package.swift`, so an app can use:

```swift
.package(url: "https://github.com/markdsparks/operon.git", from: "0.3.0")
```

The core driver, SQLite grounding, and memory support iOS 16+ and macOS 13+.
Apple Foundation Models stays isolated in its own iOS 26+/macOS 26+ product.

## The complete protocol is reachable from Swift

Swift can now load typed session artifacts before planning, prepare and invoke
app-owned skills, search scoped memory, validate output, stream provisional
generation, cancel work, and return typed completed, clarification, abstained,
or cancelled outcomes. Unknown commands fail as protocol events instead of
terminating the app driver.

The included Apple storage layer provides incremental SQLite FTS5 document
grounding and scoped indexed durable memory without a third-party dependency.

## Evidence that can be checked

Extractive grounding requires every claim to carry one or more evidence quotes.
Operon canonicalizes the retrieved chunk, checks each quote as an exact
substring, derives byte offsets and citations, and repairs or abstains when the
contract fails. A model may also explicitly return an unsupported-by-sources
abstention.

This proves attribution, not semantic entailment. A quote can exist while a
bad paraphrase overstates it, so GroundBench reports unsupported answers as a
separate number.

## Measured result

Eight GroundBench cases—four answerable and four deliberately unsupported—were
repeated three times with local Qwen3 4B Q4_K_M. Both raw and Operon arms saw
the same canonical evidence.

| Configuration | Complete supported answers | Safe refusal | Every quote exact | Median latency |
| --- | ---: | ---: | ---: | ---: |
| Raw full context | 75.0% | 0.0% | 75.0% | 1,265 ms |
| Operon citation | 25.0% | 50.0% | n/a | 640 ms |
| **Operon extractive** | **75.0%** | **41.7%** | **100.0%** | **1,197 ms** |

This is a small development benchmark on an Apple Silicon desktop, not an
iPhone result or a general model ranking. The exact-quote guarantee is
deterministic; the observed refusal and completion rates are model-and-corpus
measurements. See [GroundBench](benchmarks/GROUNDBENCH.md) and the
[machine-readable summary](benchmarks/published/groundbench-qwen3-4b-v0.3-3x.summary.json).

## Also in v0.3

- browser `AbortSignal`, progress, and provisional update support;
- JSON Schema array bounds and local reusable definitions;
- cancellation through Rust, C, WASM, JavaScript, and Swift;
- validation exhaustion as an abstention by default; and
- Apple measurement events for latency, tokens, thermal state, and low-power state.
