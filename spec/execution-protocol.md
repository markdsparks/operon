# Operon execution protocol

Status: experimental 0.2

The execution protocol separates Operon's deterministic cognitive state machine
from platform-owned asynchronous work. The core never opens a socket, reads a
database, starts a thread, or invokes a platform model API. Instead it yields a
command and waits for the host SDK to resume it with the corresponding event.

## Goals

- Preserve identical planning, grounding, validation, and repair behavior across
  Swift, Kotlin, Python, and future hosts.
- Let every host use its native concurrency, cancellation, storage, and model
  APIs.
- Make complete executions recordable and replayable without a live model.
- Keep network authority and side effects outside the portable core.

## Lifecycle

1. A host creates an execution session with a query and policy.
2. `start` returns either a command or a completed result.
3. The host performs the command asynchronously.
4. The host passes a matching event to `resume`.
5. Steps 2–4 repeat until completion or a terminal error.

Only one command may be outstanding for a session. Every command carries a
monotonically increasing request ID. An event with a stale or unexpected ID is
rejected.

When configured with a session ID, the first command is `LoadSession`. It
returns bounded typed artifacts before planning, so a model resolves “there” or
“that evening” from application state rather than reconstructing it from prose.
Artifacts carry a host-private value plus a model-safe summary; only the ID,
kind, and summary enter model prompts.

When skills declare `consumes` and `produces`, Operon compiles the portion of
the capability graph that can satisfy an optional completion contract. Only
capabilities whose typed dependencies are present enter the ready set. That set
is enforced in both the prompt catalog and structured decoding schema, so a
small model cannot repeat a completed lookup or jump past a prerequisite.

## Commands

### Load session

Requests bounded ephemeral artifacts for a host-owned session. These are not
durable memory: they represent recent task focus, view state, drafts, and prior
results and may expire after a turn. The host controls their contents and
retention.

### Generate

Requests structured generation from the selected model provider. The command
contains the stage, messages, output schema, temperature, output limit,
reasoning budget, and timeout.

### Retrieve

Requests relevant evidence from a grounding provider. It contains the retrieval
query and maximum number of sources. Supplying grounding to a session is an
authoritative application decision; a model-generated plan cannot disable it.

### Search memory

Requests durable records from a host-owned memory store. It contains a query,
maximum result count, and a mandatory `MemoryScope` (namespace, optional
subject, and allowed sensitivities). Hosts apply scope, retention, validity, and
status filters before any relevance ranking. Returned records carry type,
authority, provenance, temporal fields, and status; they are historical data,
not instructions.

The protocol defines read access only. Applications write, supersede, tombstone,
export, and delete records through their storage adapter. A model cannot acquire
durable-memory write authority by emitting text.

When a session is configured with a `MemoryScope`, the core yields Search memory
after planning and before grounding/generation. Returned records are compiled
into the bounded local context as attributed historical data; they are not
instructions and do not bypass source or output validation.

### Validate output

Requests application-owned validation of the candidate `output` value after
the core has completed its structural and evidence checks. Hosts return a list
of actionable error strings. Empty errors complete the session; non-empty
errors are supplied to a bounded targeted-repair command. This preserves the
boundary between deterministic business rules in the app and model-generated
interpretation.

### Invoke skill

Requests one application-registered capability. A session configuration supplies
the finite registry of descriptors, each with an ID, typed input/output schemas,
and whether the host must obtain user confirmation. The planner may request a
call only from that registry; the core drops unknown calls and calls whose
arguments do not validate. The host remains responsible for permission prompts,
side effects, and the actual implementation. A validated skill result becomes
attributable local source context for the answer stage.

Each invocation carries an `idempotency_key`. Hosts use it to deduplicate a
side effect if an outstanding command is redelivered after suspension or crash
recovery.

### Prepare skill

Requests host-side resolution of a partial skill call before invocation. The
model may use semantic references such as `last_result`; the host maps those to
canonical IDs, dates, locations, or UI targets using typed session artifacts.
Only a `ready` result with arguments satisfying the descriptor schema may yield
`InvokeSkill`.

## Events

### Generation completed

Returns model text and optional usage metadata for a matching Generate command.

### Session loaded

Returns bounded `SessionArtifact` values for a matching Load session command.

### Retrieval completed

Returns ordered sources for a matching Retrieve command.

### Memory search completed

Returns ordered `MemoryRecord` values for a matching Search memory command.

### Output validated

Returns zero or more application validation errors for a matching Validate
output command.

### Skill completed

Returns the typed output and optional provenance sources for a matching Invoke
skill command. The core checks the output against the registered descriptor
before it can enter model context.

### Skill prepared

Returns one of `ready`, `needs_input`, `rejected`, or `unavailable` for a
matching Prepare skill command. `needs_input` completes the turn with a typed
clarification instead of a generic fallback answer.

### Command failed

Returns a categorized host error for the outstanding command. Protocol 0.2
treats this as terminal. Later versions may add policy-controlled fallback and
retry commands.

## Completion

A completed result contains:

- human-readable answer;
- optional application-typed output;
- cited sources and declared source IDs;
- normalized confidence;
- task plan;
- repair status;
- portable trace events; and
- ordered skill receipts with idempotency keys and published artifact IDs.

It may instead contain a structured clarification with its missing fields and
the relevant skill ID. The `require_skill_or_clarification` policy ensures an
action-oriented session cannot return an unsupported generic answer.

If a `CompletionContract` is present, every required skill ID and artifact kind
must be observed before normal completion. An unmet contract produces a typed
clarification instead of plausible success text.

## Snapshots

`ExecutionSession::snapshot` captures versioned state at a command boundary;
`ExecutionSession::restore` resumes without replaying completed work. Equivalent
entry points are exposed through WASM and the C ABI. The host persists the
outstanding command beside the snapshot and returns its matching event after
restore. Snapshots include private artifact values and must be protected like
application data.

## Compatibility

Serialized commands, events, traces, and results carry `protocol_version`.
Adding optional fields is backward compatible within a major protocol version.
Removing fields, changing meanings, or changing state-transition requirements
requires a new major version.

The initial synchronous Rust runtime remains as a host adapter: it executes each
yielded command through its existing inference and grounding traits and resumes
the session. Native SDKs should drive sessions directly.

## Context compilation

`operon-core` provides a deterministic character-budget context compiler. It
allocates bounded space to session context, typed durable memory, and grounding
sources, clips only at Unicode boundaries, and reports omitted memory/source
counts. Hosts remain responsible for obtaining authorized session and memory
records, while the future C ABI will make this exact compiler available to each
native SDK.

## Security boundary

The core is pure orchestration and has no ambient authority. The host decides
which providers, documents, skills, and network capabilities exist. A local-only
policy must be enforced when providers are admitted, before execution begins.
