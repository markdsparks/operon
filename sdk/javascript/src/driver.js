/**
 * Browser host driver for the Operon WASM command/event protocol.
 *
 * The WASM module owns deterministic orchestration. This driver dispatches its
 * commands to application-owned model, grounding, memory, and validation
 * functions. It is safe to run inside a Web Worker and has no Node dependency.
 */

export const EXECUTION_PROTOCOL_VERSION = "0.1";

export const HostFailure = Object.freeze({
  provider: "provider",
  grounding: "grounding",
  memory: "memory",
  cancelled: "cancelled",
  timeout: "timeout"
});

function protocolError(message) {
  return new Error(`Operon protocol error: ${message}`);
}

function parseStep(json) {
  let step;
  try {
    step = JSON.parse(json);
  } catch {
    throw protocolError("WASM session returned invalid JSON");
  }
  if (!step || (step.kind !== "command" && step.kind !== "complete")) {
    throw protocolError("WASM session returned an unknown step");
  }
  return step;
}

function failureFor(command) {
  if (command.kind === "retrieve") return HostFailure.grounding;
  if (command.kind === "search_memory") return HostFailure.memory;
  return HostFailure.provider;
}

function eventFor(command, value) {
  const protocolVersion = command.protocol_version;
  if (!protocolVersion) throw protocolError("command is missing protocol_version");
  const requestId = command.request_id;
  switch (command.kind) {
    case "generate":
      return { kind: "generation_completed", protocol_version: protocolVersion, request_id: requestId, response: value };
    case "retrieve":
      return { kind: "retrieval_completed", protocol_version: protocolVersion, request_id: requestId, sources: value };
    case "search_memory":
      return { kind: "memory_search_completed", protocol_version: protocolVersion, request_id: requestId, records: value };
    case "validate_output":
      return { kind: "output_validated", protocol_version: protocolVersion, request_id: requestId, errors: value };
    default:
      throw protocolError(`unsupported command kind ${command.kind}`);
  }
}

/**
 * Drives one WASM session to completion.
 *
 * Host methods receive the complete protocol command and must return the event
 * payload only: a GenerationResponse, Source[], MemoryRecord[], or string[].
 */
export async function runSession(session, host) {
  if (!session || typeof session.start !== "function" || typeof session.resume !== "function") {
    throw new TypeError("session must provide start() and resume(eventJson)");
  }
  let step = parseStep(session.start());
  while (step.kind === "command") {
    const command = step.command;
    if (!command?.kind) throw protocolError("command step is missing command.kind");
    let event;
    try {
      let payload;
      switch (command.kind) {
        case "generate": payload = await host.generate(command); break;
        case "retrieve": payload = await host.retrieve(command); break;
        case "search_memory":
          if (typeof host.searchMemory !== "function") throw new Error("host does not implement searchMemory");
          payload = await host.searchMemory(command);
          break;
        case "validate_output":
          if (typeof host.validateOutput !== "function") throw new Error("host does not implement validateOutput");
          payload = await host.validateOutput(command);
          break;
        default: throw protocolError(`unsupported command kind ${command.kind}`);
      }
      event = eventFor(command, payload);
    } catch (error) {
      event = {
        kind: "command_failed",
        protocol_version: command.protocol_version,
        request_id: command.request_id,
        failure: failureFor(command),
        message: error instanceof Error ? error.message : String(error)
      };
    }
    step = parseStep(session.resume(JSON.stringify(event)));
  }
  return step.result;
}

/** Creates a session from a wasm-bindgen module generated from operon-core. */
export function createBrowserDriver(wasm) {
  if (!wasm || typeof wasm.OperonWasmSession !== "function") {
    throw new TypeError("wasm must export OperonWasmSession");
  }
  return {
    protocolVersion: wasm.execution_protocol_version?.() ?? EXECUTION_PROTOCOL_VERSION,
    async run(query, config, host) {
      const session = new wasm.OperonWasmSession(query, JSON.stringify(config ?? {}));
      try {
        return await runSession(session, host);
      } finally {
        session.free?.();
      }
    }
  };
}
