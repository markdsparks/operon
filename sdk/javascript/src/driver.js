/**
 * Browser host driver for the Operon WASM command/event protocol.
 *
 * The WASM module owns deterministic orchestration. This driver dispatches its
 * commands to application-owned model, grounding, memory, and validation
 * functions. It is safe to run inside a Web Worker and has no Node dependency.
 */

export const EXECUTION_PROTOCOL_VERSION = "0.3";

export const HostFailure = Object.freeze({
  provider: "provider",
  grounding: "grounding",
  memory: "memory",
  session: "session",
  skill: "skill",
  cancelled: "cancelled",
  timeout: "timeout",
  protocol: "protocol"
});

class CancelledRun extends Error {
  constructor(reason) {
    super(reason);
    this.name = "AbortError";
  }
}

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
  if (command.kind === "load_session") return HostFailure.session;
  if (command.kind === "invoke_skill") return HostFailure.skill;
  return HostFailure.provider;
}

function eventFor(command, value) {
  const protocolVersion = command.protocol_version;
  if (!protocolVersion) throw protocolError("command is missing protocol_version");
  const requestId = command.request_id;
  switch (command.kind) {
    case "load_session":
      return { kind: "session_loaded", protocol_version: protocolVersion, request_id: requestId, artifacts: value };
    case "generate":
      return { kind: "generation_completed", protocol_version: protocolVersion, request_id: requestId, response: value };
    case "retrieve":
      return { kind: "retrieval_completed", protocol_version: protocolVersion, request_id: requestId, sources: value };
    case "search_memory":
      return { kind: "memory_search_completed", protocol_version: protocolVersion, request_id: requestId, records: value };
    case "validate_output":
      return { kind: "output_validated", protocol_version: protocolVersion, request_id: requestId, errors: value };
    case "invoke_skill":
      return { kind: "skill_completed", protocol_version: protocolVersion, request_id: requestId, result: value };
    case "prepare_skill":
      return { kind: "skill_prepared", protocol_version: protocolVersion, request_id: requestId, outcome: value };
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
function cancellationReason(signal) {
  if (typeof signal?.reason === "string" && signal.reason) return signal.reason;
  if (signal?.reason instanceof Error && signal.reason.message) return signal.reason.message;
  return "cancelled by caller";
}

async function runHostCommand(handler, command, signal, onProgress, receiver) {
  if (signal?.aborted) throw new CancelledRun(cancellationReason(signal));
  const context = {
    signal,
    onUpdate: async (update) => {
      await onProgress?.({ kind: "generation_update", command, update });
    }
  };
  const work = Promise.resolve().then(() => handler.call(receiver, command, context));
  if (!signal) return work;

  let handleAbort;
  const aborted = new Promise((_, reject) => {
    handleAbort = () => reject(new CancelledRun(cancellationReason(signal)));
    signal.addEventListener("abort", handleAbort, { once: true });
  });
  try {
    return await Promise.race([work, aborted]);
  } finally {
    signal.removeEventListener("abort", handleAbort);
  }
}

function cancelSession(session, reason) {
  if (typeof session.cancel !== "function") {
    throw protocolError("session does not support cancellation");
  }
  const step = parseStep(session.cancel(reason));
  if (step.kind !== "complete") {
    throw protocolError("cancelling a session did not return a terminal result");
  }
  return step.result;
}

async function driveSession(session, host, initialStep, options = {}) {
  if (!session || typeof session.start !== "function" || typeof session.resume !== "function") {
    throw new TypeError("session must provide start() and resume(eventJson)");
  }
  let step = initialStep;
  while (step.kind === "command") {
    const command = step.command;
    if (!command?.kind) throw protocolError("command step is missing command.kind");
    if (options.signal?.aborted) {
      const reason = cancellationReason(options.signal);
      await options.onProgress?.({ kind: "cancelled", command, reason });
      return cancelSession(session, reason);
    }
    await options.onProgress?.({ kind: "command_started", command });
    if (typeof host.checkpoint === "function" && typeof session.snapshot === "function") {
      await host.checkpoint({ snapshot: session.snapshot(), command });
    }
    let event;
    try {
      let payload;
      switch (command.kind) {
        case "load_session":
          if (typeof host.loadSession !== "function") throw new Error("host does not implement loadSession");
          payload = await runHostCommand(host.loadSession, command, options.signal, options.onProgress, host);
          break;
        case "generate": payload = await runHostCommand(host.generate, command, options.signal, options.onProgress, host); break;
        case "retrieve": payload = await runHostCommand(host.retrieve, command, options.signal, options.onProgress, host); break;
        case "search_memory":
          if (typeof host.searchMemory !== "function") throw new Error("host does not implement searchMemory");
          payload = await runHostCommand(host.searchMemory, command, options.signal, options.onProgress, host);
          break;
        case "validate_output":
          if (typeof host.validateOutput !== "function") throw new Error("host does not implement validateOutput");
          payload = await runHostCommand(host.validateOutput, command, options.signal, options.onProgress, host);
          break;
        case "invoke_skill":
          if (typeof host.invokeSkill !== "function") throw new Error("host does not implement invokeSkill");
          payload = await runHostCommand(host.invokeSkill, command, options.signal, options.onProgress, host);
          break;
        case "prepare_skill":
          if (typeof host.prepareSkill !== "function") throw new Error("host does not implement prepareSkill");
          payload = await runHostCommand(host.prepareSkill, command, options.signal, options.onProgress, host);
          break;
        default: throw protocolError(`unsupported command kind ${command.kind}`);
      }
      event = eventFor(command, payload);
    } catch (error) {
      if (error instanceof CancelledRun || options.signal?.aborted) {
        const reason = error instanceof Error ? error.message : cancellationReason(options.signal);
        await options.onProgress?.({ kind: "cancelled", command, reason });
        return cancelSession(session, reason);
      }
      event = {
        kind: "command_failed",
        protocol_version: command.protocol_version,
        request_id: command.request_id,
        failure: failureFor(command),
        message: error instanceof Error ? error.message : String(error)
      };
    }
    await options.onProgress?.({ kind: "command_completed", command, event });
    step = parseStep(session.resume(JSON.stringify(event)));
  }
  await options.onProgress?.({ kind: "completed", result: step.result });
  return step.result;
}

export async function runSession(session, host, options = {}) {
  return driveSession(session, host, parseStep(session.start()), options);
}

/** Creates a session from a wasm-bindgen module generated from operon-core. */
export function createBrowserDriver(wasm) {
  if (!wasm || typeof wasm.OperonWasmSession !== "function") {
    throw new TypeError("wasm must export OperonWasmSession");
  }
  return {
    protocolVersion: wasm.execution_protocol_version?.() ?? EXECUTION_PROTOCOL_VERSION,
    async run(query, config, host, options = {}) {
      const session = new wasm.OperonWasmSession(query, JSON.stringify(config ?? {}));
      try {
        return await runSession(session, host, options);
      } finally {
        session.free?.();
      }
    },
    /** Restores a checkpoint and safely redelivers its outstanding command. */
    async restore(checkpoint, host, options = {}) {
      if (!checkpoint?.snapshot || !checkpoint?.command) {
        throw new TypeError("checkpoint must contain snapshot and command");
      }
      if (typeof wasm.OperonWasmSession.fromSnapshot !== "function") {
        throw new TypeError("WASM bundle does not support snapshot restoration");
      }
      const session = wasm.OperonWasmSession.fromSnapshot(checkpoint.snapshot);
      try {
        return await driveSession(session, host, {
          kind: "command",
          command: checkpoint.command
        }, options);
      } finally {
        session.free?.();
      }
    }
  };
}
