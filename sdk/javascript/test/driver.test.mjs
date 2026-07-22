import assert from "node:assert/strict";
import test from "node:test";

import { createBrowserDriver, runSession } from "../src/driver.js";

class ScriptedSession {
  constructor(steps) { this.steps = [...steps]; this.events = []; }
  start() { return JSON.stringify(this.steps.shift()); }
  resume(event) { this.events.push(JSON.parse(event)); return JSON.stringify(this.steps.shift()); }
}

const generate = {
  kind: "command",
  command: { kind: "generate", protocol_version: "0.2", request_id: 1, stage: "answer", request: { messages: [] } }
};

test("dispatches generation and returns the completed Rust result", async () => {
  const result = { answer: "Grounded answer", sources: [], confidence: 0.9 };
  const session = new ScriptedSession([generate, { kind: "complete", result }]);
  const actual = await runSession(session, {
    generate: async (command) => {
      assert.equal(command.request_id, 1);
      return { text: "{\"answer\":\"Grounded answer\"}" };
    }
  });
  assert.deepEqual(actual, result);
  assert.equal(session.events[0].kind, "generation_completed");
  assert.equal(session.events[0].request_id, 1);
});

test("returns a typed command failure when a host command rejects", async () => {
  const session = new ScriptedSession([generate, { kind: "complete", result: { answer: "" } }]);
  await runSession(session, { generate: async () => { throw new Error("WebLLM worker unavailable"); } });
  assert.deepEqual(session.events[0], {
    kind: "command_failed", protocol_version: "0.2", request_id: 1,
    failure: "provider", message: "WebLLM worker unavailable"
  });
});

test("dispatches an app-owned skill and preserves its typed result", async () => {
  const invokeSkill = {
    kind: "command",
    command: {
      kind: "invoke_skill", protocol_version: "0.2", request_id: 4,
      skill_id: "calendar.availability", arguments: { day: "Friday" },
      requires_user_confirmation: true
    }
  };
  const session = new ScriptedSession([invokeSkill, { kind: "complete", result: { answer: "Done" } }]);
  await runSession(session, {
    invokeSkill: async (command) => {
      assert.equal(command.requires_user_confirmation, true);
      assert.equal(command.arguments.day, "Friday");
      return { output: { open: true }, sources: [] };
    }
  });
  assert.deepEqual(session.events[0], {
    kind: "skill_completed", protocol_version: "0.2", request_id: 4,
    result: { output: { open: true }, sources: [] }
  });
});

test("loads typed session state and prepares a partial skill call", async () => {
  const load = { kind: "command", command: { kind: "load_session", protocol_version: "0.2", request_id: 1, session_id: "turn-7", limit: 8 } };
  const prepare = { kind: "command", command: { kind: "prepare_skill", protocol_version: "0.2", request_id: 2, skill_id: "forecast.hourly", partial_arguments: { window_ref: "last_result" }, artifacts: [{ id: "A1", kind: "forecast-window", summary: "Nokomis tomorrow evening" }] } };
  const session = new ScriptedSession([load, prepare, { kind: "complete", result: { clarification: null } }]);
  await runSession(session, {
    loadSession: async () => [{ id: "A1", kind: "forecast-window", summary: "Nokomis tomorrow evening", value: { place: "Nokomis" } }],
    prepareSkill: async (command) => {
      assert.equal(command.partial_arguments.window_ref, "last_result");
      return { kind: "ready", arguments: { place: "Nokomis", date: "2026-07-23" } };
    }
  });
  assert.equal(session.events[0].kind, "session_loaded");
  assert.equal(session.events[1].kind, "skill_prepared");
});

test("creates and frees a wasm-bindgen session", async () => {
  let freed = false;
  const wasm = {
    execution_protocol_version: () => "0.2",
    OperonWasmSession: class extends ScriptedSession {
      constructor(query, config) {
        assert.equal(query, "Will the hike work?");
        assert.deepEqual(JSON.parse(config), { has_grounding: true });
        super([generate, { kind: "complete", result: { answer: "Yes" } }]);
      }
      free() { freed = true; }
    }
  };
  const answer = await createBrowserDriver(wasm).run(
    "Will the hike work?", { has_grounding: true }, { generate: async () => ({ text: "{}" }) }
  );
  assert.equal(answer.answer, "Yes");
  assert.equal(freed, true);
});
