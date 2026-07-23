# Operon browser driver

This package drives the canonical Rust execution session inside a browser or
Web Worker. It does not make network requests, load a model, or read device
data. The host application owns those authorities and resumes the WASM session
with versioned protocol events.

This is a general integration boundary: the app keeps its WebLLM worker (or
other local provider), deterministic services, data, and permissions. A weather
engine is one useful example, not a product constraint.

## Build the WASM module

```bash
rustup target add wasm32-unknown-unknown
cargo install wasm-bindgen-cli --version 0.2.126 --locked
cd sdk/javascript
npm run build:wasm
```

The generated `pkg/` module is intentionally ignored by Git. Import its
default initializer and pass the initialized module to `createBrowserDriver`.

## Web Worker host

```js
import init, * as wasm from "./pkg/operon_core.js";
import { createBrowserDriver } from "@operon-ai/browser";

await init();
const operon = createBrowserDriver(wasm);
const result = await operon.run(
  "Can I hike Saturday morning?",
  { has_grounding: true, has_application_validator: true },
  {
    generate: async ({ request }) => nearcastWebLLM(request),
    loadSession: async ({ session_id, limit }) => loadTypedArtifacts(session_id, limit),
    prepareSkill: async ({ skill_id, partial_arguments, artifacts }) =>
      prepareApplicationSkill(skill_id, partial_arguments, artifacts),
    retrieve: async ({ query, limit }) => weatherSnapshotSources(query, limit),
    invokeSkill: async ({ skill_id, arguments, requires_user_confirmation }) =>
      runApplicationSkill(skill_id, arguments, requires_user_confirmation),
    validateOutput: async ({ output }) => validateNearcastAnswer(output)
  }
);
```

`generate` returns a protocol `GenerationResponse`; `retrieve` returns `Source[]`;
`loadSession` returns bounded typed `SessionArtifact[]` before planning;
`prepareSkill` returns `ready`, `needs_input`, `rejected`, or `unavailable`;
`searchMemory` returns `MemoryRecord[]` when enabled; and `validateOutput`
returns a string array of application validation errors. `invokeSkill` returns
`{ output, sources }` after the app has performed any required confirmation.
A rejected operation is
reported to Rust as a typed `command_failed` event, never converted into an
invented answer.

## Checkpoint and restore

Provide an optional `checkpoint` host method to persist the versioned snapshot
and its outstanding command before dispatch. After an app restart, pass that
object to `operon.restore(checkpoint, host)`. The same command is redelivered
with the same request ID and skill `idempotency_key`, allowing the app to
deduplicate side effects safely.

```js
const host = {
  checkpoint: ({ snapshot, command }) =>
    savePrivateState({ snapshot, command }),
  generate,
  prepareSkill,
  invokeSkill
};

const result = await operon.restore(await loadPrivateState(), host);
```

## Development

```bash
cd sdk/javascript
npm test
npm run test:wasm # after npm run build:wasm
```

The tests use a scripted session, so they do not require a browser, model, or
compiled WASM artifact.
