# Operon execution protocol

Status: experimental 0.1

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

## Commands

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

### Validate output

Requests application-owned validation of the candidate `output` value after
the core has completed its structural and evidence checks. Hosts return a list
of actionable error strings. Empty errors complete the session; non-empty
errors are supplied to a bounded targeted-repair command. This preserves the
boundary between deterministic business rules in the app and model-generated
interpretation.

## Events

### Generation completed

Returns model text and optional usage metadata for a matching Generate command.

### Retrieval completed

Returns ordered sources for a matching Retrieve command.

### Memory search completed

Returns ordered `MemoryRecord` values for a matching Search memory command.

### Output validated

Returns zero or more application validation errors for a matching Validate
output command.

### Command failed

Returns a categorized host error for the outstanding command. Protocol 0.1
treats this as terminal. Later versions may add policy-controlled fallback and
retry commands.

## Completion

A completed result contains:

- human-readable answer;
- optional application-typed output;
- cited sources and declared source IDs;
- normalized confidence;
- task plan;
- repair status; and
- portable trace events.

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
which providers, documents, tools, and network capabilities exist. A local-only
policy must be enforced when providers are admitted, before execution begins.
