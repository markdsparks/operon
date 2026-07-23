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

> Status: v0.2 alpha with a portable Rust core, a dependency-free Python
> SDK/CLI, a developer-preview Swift package for Apple platforms, and an
> experimental browser/Web Worker WASM driver. Public contracts remain
> intentionally small and experimental.

See the [v0.2 release notes](RELEASE_NOTES.md) and [changelog](CHANGELOG.md).

**AppBench evidence:** on 20 synthetic app tasks repeated three times, the same
local Qwen3 4B model completed 90% with the original Operon harness versus 20%
in a raw full-state tool loop. v0.2 then targeted the measured multi-step gap:
all 12 dependent jobs completed with exact routing and arguments, versus 6 of
12 with linear Operon replanning and 0 of 12 in the raw loop. Read the
[methodology](benchmarks/APPBENCH.md) and
[development results](benchmarks/APPBENCH_RESULTS.md). This is engineering
evidence, not a general model ranking.

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
required fields, and additional-property control.

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

## What v0.2 does

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
- Runs a bounded, targeted repair when validation fails.
- Repairs missing markers deterministically when every declared source is valid.
- Returns the plan, cited sources, confidence, repair state, and execution trace.

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
- `sdk/swift`: working iOS/macOS package, Apple Foundation Models provider, and
  grounded typed-decision demo
- `sdk/javascript`: browser/Web Worker host driver for the Rust WASM session
- `spec`: versioned command, event, output, and trace contracts
- `conformance`: deterministic cross-SDK replay fixtures
- `benchmarks`: model capability evaluation, separate from conformance

The Rust core deliberately does not embed an inference engine or async runtime.
Applications implement its inference and grounding traits, while native SDKs
control scheduling and platform services.

The Swift developer preview proves the native API and real on-device provider
boundary. It currently implements the vertical-slice state transitions in pure
Swift. `OperonCoreFFI` and `OperonCoreDriver` now drive Rust command/event
sessions through the C ABI using app-owned Swift model and grounding providers;
the generated XCFramework links this path for iOS development. The existing
public `OperonKit` API remains available while that migration continues.

The experimental C ABI is now available for native hosts. It exposes opaque
session handles and versioned JSON commands/events while leaving inference,
storage, and platform authority in the host. See the [C ABI guide](docs/ffi/c-abi.md).

The first real-model integration result is recorded in
[benchmarks/SMOKE.md](benchmarks/SMOKE.md). It is evidence that the complete
pipeline works, not a general capability claim.

The repeatable four-configuration evaluation harness is documented in
[benchmarks/README.md](benchmarks/README.md).
The app-task comparison and first repeated development run are documented in
[benchmarks/APPBENCH.md](benchmarks/APPBENCH.md) and
[benchmarks/APPBENCH_RESULTS.md](benchmarks/APPBENCH_RESULTS.md).
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
