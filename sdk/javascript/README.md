# Operon browser driver

This package drives the canonical Rust execution session inside a browser or
Web Worker. It does not make network requests, load a model, or read device
data. The host application owns those authorities and resumes the WASM session
with versioned protocol events.

This is the integration boundary Nearcast needs: its existing WebLLM worker
remains the local inference provider, while Nearcast's deterministic weather
engine remains the only source of forecast, alert, freshness, and plan-decision
facts.

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
    retrieve: async ({ query, limit }) => weatherSnapshotSources(query, limit),
    validateOutput: async ({ output }) => validateNearcastAnswer(output)
  }
);
```

`generate` returns a protocol `GenerationResponse`; `retrieve` returns `Source[]`;
`searchMemory` returns `MemoryRecord[]` when enabled; and `validateOutput`
returns a string array of application validation errors. A rejected operation is
reported to Rust as a typed `command_failed` event, never converted into an
invented answer.

## Development

```bash
cd sdk/javascript
npm test
npm run test:wasm # after npm run build:wasm
```

The tests use a scripted session, so they do not require a browser, model, or
compiled WASM artifact.
