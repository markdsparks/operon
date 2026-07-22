import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

import init, * as wasm from "../pkg/operon_core.js";
import { createBrowserDriver } from "../src/driver.js";

await init({
  module_or_path: await readFile(new URL("../pkg/operon_core_bg.wasm", import.meta.url))
});

const result = await createBrowserDriver(wasm).run("Hello", {}, {
  generate: async () => ({
    text: JSON.stringify({
      answer: "Hello from local Operon.",
      confidence: 0.9,
      used_source_ids: []
    })
  })
});

assert.equal(wasm.execution_protocol_version(), "0.2");
assert.equal(result.answer, "Hello from local Operon.");
console.log("WASM protocol smoke passed");
