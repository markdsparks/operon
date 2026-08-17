# Operon

Operon is a drop-in, local-first runtime for the small language model already
in your app. Keep your existing provider, put Operon around it, and get an
immediate upgrade in planning, structured execution, validation, repair, and
inspectable traces. Then add local knowledge, app-owned skills, session context,
and memory as your product grows.

```text
query → plan → ready actions → prepare → act → verify completion → response
```

Operon is not an inference engine. It sits above inference engines and makes
constrained models more useful through orchestration and explicit structure.

> Status: v0.4 alpha with a portable Rust core, Python and JavaScript hosts,
> and a Swift package that can be added directly from GitHub on Apple
> platforms. Public contracts remain
> intentionally small and experimental.

See the [v0.4 release notes](RELEASE_NOTES.md) and [changelog](CHANGELOG.md).

**AppBench evidence:** on 20 synthetic app tasks repeated three times, the same
local Qwen3 4B model completed 90% with the original Operon harness versus 20%
in a raw full-state tool loop. v0.2 then targeted the measured multi-step gap:
all 12 dependent jobs completed with exact routing and arguments, versus 6 of
12 with linear Operon replanning and 0 of 12 in the raw loop. Read the
[methodology](benchmarks/APPBENCH.md) and
[development results](benchmarks/APPBENCH_RESULTS.md). This is engineering
evidence, not a general model ranking.

**GroundBench evidence:** on eight answerable and deliberately unanswerable
local-knowledge cases repeated three times, Qwen3 4B with v0.3 extractive
grounding produced exact-substring evidence on 100% of its quote-bearing
records, versus 75% for a raw full-context prompt. Complete supported answers
were 75% in both arms. Safe refusal was only 41.7% with strict Operon, so v0.3
does **not** claim deterministic semantic entailment: it verifies extraction,
and keeps unsupported-claim detection as a measured gap. Read the
[GroundBench methodology](benchmarks/GROUNDBENCH.md) and
[published summary](benchmarks/published/groundbench-qwen3-4b-v0.3-3x.summary.json).

## Quick start

Operon currently speaks the OpenAI-compatible chat completions protocol used
by Ollama, llama-server, LM Studio, and similar local servers. For example,
with Ollama running locally:

```bash
export OPERON_MODEL=qwen3:4b
PYTHONPATH=sdk/python/src python3 -m operon \
  --ground ./documents \
  --trace \
  "Compare the return policy with this customer's request"
```

Pass `--output-schema schema.json --json` when a shell script or application
needs validated machine-readable output.

See [examples/python-ollama/typed_decision.py](examples/python-ollama/typed_decision.py) and
[examples/python-ollama/meal-decision-schema.json](examples/python-ollama/meal-decision-schema.json) for
complete library and CLI-ready examples.

Operon requests `reasoning_effort: none` for its current structured stages.
This prevents thinking-capable small models from exhausting a bounded output
budget before emitting the required JSON. Reasoning strategy will become an
adaptive policy rather than a provider-global switch in a later milestone.

Or use it as a library:

```python
from operon import LocalDocuments, OpenAICompatibleProvider, Operon

provider = OpenAICompatibleProvider(
    model="qwen3:4b",
    base_url="http://127.0.0.1:11434/v1",
)

model = Operon.wrap(
    provider,
    grounding=LocalDocuments("./documents"),
)

result = model.run("Which cancellation terms apply to this request?")
print(result.answer)
print(result.sources)
print(result.trace.events)
```

For claims that must carry mechanically checkable evidence, enable extractive
grounding. Operon canonicalizes each retrieved chunk, requires every claim to
carry a quote, verifies that quote as an exact substring, derives byte offsets
and citations, and returns a typed abstention when validation is exhausted or
the model reports that the sources do not support an answer.

```python
from operon import Policy

model = Operon.wrap(
    provider,
    grounding=LocalDocuments("./documents"),
    policy=Policy(grounding_mode="extractive"),
)

result = model.run("What retention period does this policy require?")
if result.status == "completed":
    print(result.answer, result.claims)
else:
    print(result.abstention)
```

### Swift Package Manager

Apple apps can consume Operon from the repository root; the Rust XCFramework
is a checksummed GitHub release asset rather than a vendored build step.

```swift
dependencies: [
  .package(url: "https://github.com/markdsparks/operon.git", from: "0.4.0")
]
```

Core, driver, SQLite grounding, and memory support iOS 16+ and macOS 13+.
`OperonFoundationModels` is a separate product that requires iOS 26+ or macOS
26+, so older systems can use another local provider without raising the whole
package floor. See the [Swift integration guide](sdk/swift/README.md).

The first boost is one wrapper and one readable result. With no knowledge,
memory, or skills attached, the automatic profile stays on the one-call fast
path; deterministic validation and a targeted repair are added around the
existing provider.

```swift
import OperonCoreDriver
import OperonFoundationModels

let ai = OperonRuntime.wrap(AppleFoundationModelsProvider())
let result = try await ai.ask("Turn this description into a practical plan")

print(result.answer)
print(result.status)
```

Attach grounding, typed session state, memory, and app-owned skills only when
the product needs them. `OperonRuntime` selects an appropriate planning profile
from those attached capabilities; an explicit `OperonPolicy` still overrides
every default.

Applications can also require typed data alongside the readable answer:

```python
model = Operon.wrap(
    provider,
    grounding=LocalDocuments("./documents"),
    output_schema={
        "type": "object",
        "properties": {
            "decision": {"type": "string", "enum": ["allow", "deny"]},
            "amount": {"type": "number", "minimum": 0},
        },
        "required": ["decision", "amount"],
        "additionalProperties": False,
    },
)

result = model.run("Apply the policy and calculate the allowed amount.")
print(result.output["decision"], result.output["amount"])
```

Operon validates this application output locally and includes field-level errors
in its bounded repair loop. The supported portable schema subset covers objects,
arrays, strings, numbers, integers, booleans, nulls, enums, numeric bounds,
array bounds, reusable local `$defs`/`$ref` definitions, required fields, and
additional-property control.

The default policy is local-only. Operon rejects a non-local provider URL
unless the application explicitly opts into remote execution.

For multi-session apps, the Python reference host now includes an opt-in local
SQLite session store. It resumes bounded historical conversation context without
automatically turning model output into long-term facts. See the
[Python SDK session guide](sdk/python/README.md#local-session-continuity) and
[local memory architecture](docs/research/local-memory-architecture.md).

Applications can also attach an opt-in local SQLite/FTS5 durable-memory store
for explicit facts, preferences, decisions, and episodes. Operon applies the
declared namespace, subject, sensitivity, validity, and status filters before
retrieval; the model only receives the selected records as attributed historical
data. See the [typed durable-memory guide](sdk/python/README.md#typed-durable-memory).

For live app state and deterministic actions, register a typed skill. The model
may request only a descriptor the app supplied; Operon validates its arguments,
the host retains user-confirmation and side-effect authority, and the validated
result returns as citable local context. This works for any domain—calendar,
device sensor, inventory, weather, health workflow, or internal business rule.

For follow-up actions, Operon can load typed, short-lived session artifacts
before planning and ask the host to prepare partial calls such as
`{"window_ref":"last_result"}`. This resolves references through application
state—not assistant prose—and produces a structured clarification when a needed
input is missing. Skill results can publish the next turn’s artifacts, and the
protocol permits a bounded replan for dependent actions.

Operon v0.2 adds a TaskGraph underneath that same simple wrapper. Skills may
declare typed artifact kinds through `consumes` and `produces`; an app may add
a `CompletionContract` for the skill IDs or artifact kinds that must exist
before a turn can finish. Operon compiles the goal-relevant graph, constrains
structured decoding to dependency-ready actions, and returns idempotent skill
receipts. The model interprets language; the runtime owns ordering and
completion truth.

```python
from operon import CompletionContract

# Descriptors in app_skills declare produces=("calendar.slot",) and
# consumes=("calendar.slot",) on the matching capabilities.
result = runtime.run(
    "Find 30 minutes Friday and schedule a review with Maya.",
    completion=CompletionContract(
        required_skill_ids=("calendar.create_event",),
    ),
)
print(result.skill_receipts)
```

Long-running native and browser sessions can also snapshot at a command
boundary and restore without replaying completed work. C and WASM entry points
carry the same versioned state; hosts persist the outstanding command and use
its stable idempotency key to deduplicate side effects.

## What Operon does

- Uses a fast path for simple requests and planning for complex ones.
- Turns complex queries into intent, subquestions, and answer requirements.
- Indexes local text files with a zero-dependency lexical retriever.
- Limits retrieved context to an explicit budget.
- Requests schema-constrained intermediate and final output.
- Enforces optional application-defined typed output schemas.
- Invokes only application-registered skills with typed input/output contracts.
- Compiles typed capability dependencies into a bounded, goal-directed ready set.
- Refuses normal completion while an app-defined completion contract is unmet.
- Emits replay-safe skill receipts and versioned execution snapshots.
- Validates confidence, citations, and source identifiers.
- Optionally verifies claim evidence as exact substrings with byte offsets.
- Returns completed, clarification, abstained, and cancelled outcomes as data.
- Runs a bounded, targeted repair when validation fails.
- Repairs missing markers deterministically when every declared source is valid.
- Returns the plan, cited sources, confidence, repair state, and execution trace.
- Streams provisional model output while keeping only the terminal result
  authoritative, and exposes cancellation and Apple performance samples.
- Ships incremental SQLite FTS5 grounding and scoped durable memory for Swift.

Supported grounding formats are Markdown, text, reStructuredText, JSON, YAML,
and CSV. Binary document extraction and vector retrieval are intentionally
outside the first slice.

## Development

The reference package has no runtime dependencies. Run the suite with:

```bash
PYTHONPATH=sdk/python/src python3 -m unittest discover -s sdk/python/tests -v
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
make check-apple # on Xcode 26+
```

The workspace contains:

- `crates/operon-core`: portable resumable Rust execution state machine
- `sdk/python`: executable Python SDK, local retrieval, HTTP provider, and CLI
- root `Package.swift`: versioned SwiftPM distribution backed by a release XCFramework
- `sdk/swift`: Apple Foundation Models, SQLite grounding/memory, skills,
  streaming, cancellation, and a grounded typed-decision demo
- `sdk/javascript`: browser/Web Worker host driver for the Rust WASM session
- `spec`: versioned command, event, output, and trace contracts
- `conformance`: deterministic cross-SDK replay fixtures
- `benchmarks`: model capability evaluation, separate from conformance

The Rust core deliberately does not embed an inference engine or async runtime.
Applications implement its inference and grounding traits, while native SDKs
control scheduling and platform services.

`OperonCoreFFI` and `OperonCoreDriver` drive the canonical Rust command/event
session through a release XCFramework using app-owned Swift model, grounding,
memory, session, and skill providers. Swift concurrency owns scheduling,
streaming, and cancellation; Rust owns portable execution semantics.

The experimental C ABI is now available for native hosts. It exposes opaque
session handles and versioned JSON commands/events while leaving inference,
storage, and platform authority in the host. See the [C ABI guide](docs/ffi/c-abi.md).

The first real-model integration result is recorded in
[benchmarks/SMOKE.md](benchmarks/SMOKE.md). It is evidence that the complete
pipeline works, not a general capability claim.

The repeatable five-configuration evaluation harness is documented in
[benchmarks/README.md](benchmarks/README.md).
The focused one-call wrapper comparison is documented in
[BoostBench](benchmarks/BOOSTBENCH.md); the first repeated local run is in
[BoostBench development results](benchmarks/BOOSTBENCH_RESULTS.md).
The app-task comparison and first repeated development run are documented in
[benchmarks/APPBENCH.md](benchmarks/APPBENCH.md) and
[benchmarks/APPBENCH_RESULTS.md](benchmarks/APPBENCH_RESULTS.md).
Grounded attribution and safe-refusal measurement are documented in
[benchmarks/GROUNDBENCH.md](benchmarks/GROUNDBENCH.md).
The first 30-case development result and its limitations are summarized in
[benchmarks/RESULTS.md](benchmarks/RESULTS.md).

See [ARCHITECTURE.md](ARCHITECTURE.md) for boundaries and
[ROADMAP.md](ROADMAP.md) for the path to the shared FFI core and Kotlin SDK.
Contributors should also read [CONTRIBUTING.md](CONTRIBUTING.md) and
[SECURITY.md](SECURITY.md).

## Non-goals

Operon does not claim to turn a small model into a frontier model. It improves
tasks whose search space can be reduced through planning, relevant context,
tools, typed outputs, deterministic checks, and bounded retries.
