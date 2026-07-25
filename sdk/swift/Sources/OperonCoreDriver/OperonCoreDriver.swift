import Foundation
import OperonCoreFFI
import OperonKit

/// Runs a complete Rust-core command/event session with app-owned local
/// inference and grounding providers.
///
/// The driver has no storage authority. A host may supply a local grounding
/// provider, and future memory commands will be routed to a separately scoped
/// application-owned memory provider.
public final class OperonCoreDriver: @unchecked Sendable {
  private let model: any OperonModelProvider
  private let grounding: (any OperonGroundingProvider)?
  private let memory: (any OperonMemoryStore)?
  private let memoryScope: OperonMemoryScope?
  private let policy: OperonPolicy
  private let sessionArtifacts: (any OperonSessionArtifactProvider)?
  private let skillHost: (any OperonSkillHost)?
  private let sessionID: String?
  private let completion: OperonCompletionContract?

  public init(
    model: any OperonModelProvider,
    grounding: (any OperonGroundingProvider)? = nil,
    memory: (any OperonMemoryStore)? = nil,
    memoryScope: OperonMemoryScope? = nil,
    policy: OperonPolicy = .init(),
    sessionArtifacts: (any OperonSessionArtifactProvider)? = nil,
    skillHost: (any OperonSkillHost)? = nil,
    sessionID: String? = nil,
    completion: OperonCompletionContract? = nil
  ) {
    self.model = model
    self.grounding = grounding
    self.memory = memory
    self.memoryScope = memoryScope
    self.policy = policy
    self.sessionArtifacts = sessionArtifacts
    self.skillHost = skillHost
    self.sessionID = sessionID
    self.completion = completion
  }

  /// Executes the core's command loop and returns its terminal protocol result.
  public func run(_ query: String) async throws -> OperonCoreCompletedResult {
    try await runSession(query, outputSchema: nil, validateOutput: nil, eventSink: nil)
  }

  /// Streams progress and provisional model output. Only the terminal result
  /// has passed Operon's deterministic validation.
  public func stream(_ query: String) -> AsyncThrowingStream<OperonRunEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let result = try await self.runSession(
            query,
            outputSchema: nil,
            validateOutput: nil,
            eventSink: { continuation.yield($0) }
          )
          continuation.yield(.finished(try result.status()))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Executes the core with a typed output contract and app-owned validation.
  ///
  /// The closure runs only after Rust has validated structure and evidence. Its
  /// errors are returned to Rust so it can perform a bounded targeted repair.
  public func run<Output: Codable & Sendable>(
    _ query: String,
    outputSchema: OperonSchema,
    as outputType: Output.Type = Output.self,
    validateOutput: (@Sendable (Output) -> [String])? = nil
  ) async throws -> OperonRunOutcome<Output> {
    let result = try await runSession(
      query,
      outputSchema: jsonSchema(from: outputSchema),
      validateOutput: { rawOutput in
        do {
          let data = try JSONSerialization.data(
            withJSONObject: rawOutput, options: [.fragmentsAllowed])
          let output = try JSONDecoder().decode(Output.self, from: data)
          return validateOutput?(output) ?? []
        } catch {
          return [
            "application output could not decode as \(Output.self): \(error.localizedDescription)"
          ]
        }
      },
      eventSink: nil
    )
    return try decodeTerminalOutcome(result.json, outputType: outputType)
  }

  private func runSession(
    _ query: String,
    outputSchema: [String: Any]?,
    validateOutput: (@Sendable (Any) -> [String])?,
    eventSink: (@Sendable (OperonRunEvent) -> Void)?
  ) async throws -> OperonCoreCompletedResult {
    let runStarted = ContinuousClock.now
    let availability = await model.availability()
    guard case .available = availability else {
      if case .unavailable(let reason) = availability {
        throw OperonError.modelUnavailable(reason)
      }
      throw OperonError.modelUnavailable("unknown")
    }

    let session = try OperonCoreSession(
      query: query,
      configJSON: try sessionConfigJSON(
        outputSchema: outputSchema,
        hasApplicationValidator: validateOutput != nil,
        memoryScope: memoryScope
      )
    )
    var step = try session.start()
    while true {
      switch step {
      case .complete(let json):
        eventSink?(
          .measurement(
            performanceSample(
              kind: .run,
              stage: nil,
              started: runStarted,
              promptTokens: nil,
              completionTokens: nil
            )))
        return OperonCoreCompletedResult(json: json)
      case .command(let json):
        if Task.isCancelled {
          step = try session.cancel(reason: "cancelled by caller")
          continue
        }
        let command: CoreCommand
        do {
          command = try CoreCommand.decode(json)
        } catch {
          guard let requestID = CoreCommand.requestID(from: json) else { throw error }
          step = try session.resume(
            eventJSON: failureJSON(
              requestID: requestID,
              failure: "protocol",
              message: error.localizedDescription
            ))
          continue
        }
        let event: String
        do {
          event = try await execute(
            command, validateOutput: validateOutput, eventSink: eventSink)
        } catch is CancellationError {
          event = try failureJSON(
            requestID: command.requestID,
            failure: "cancelled",
            message: "cancelled by caller"
          )
        } catch {
          event = try failureJSON(
            requestID: command.requestID,
            failure: command.failureKind,
            message: error.localizedDescription
          )
        }
        step = try session.resume(eventJSON: event)
      }
    }
  }

  private func execute(
    _ command: CoreCommand,
    validateOutput: (@Sendable (Any) -> [String])?,
    eventSink: (@Sendable (OperonRunEvent) -> Void)?
  ) async throws -> String {
    switch command.kind {
    case .generate:
      let modelStarted = ContinuousClock.now
      eventSink?(.stageStarted(command.stage))
      let stage = command.stage
      let response = try await model.generateStreaming(
        OperonGenerationRequest(
          messages: command.messages,
          schema: try command.schema.operonSchema(),
          temperature: command.temperature,
          maximumResponseTokens: command.maximumResponseTokens
        ),
        onUpdate: { eventSink?(.provisionalModelOutput(stage: stage, text: $0)) }
      )
      eventSink?(
        .measurement(
          performanceSample(
            kind: .modelCall,
            stage: stage,
            started: modelStarted,
            promptTokens: response.promptTokens,
            completionTokens: response.completionTokens
          )))
      return try eventJSON(
        kind: "generation_completed",
        requestID: command.requestID,
        values: [
          "response": [
            "text": response.text,
            "prompt_tokens": response.promptTokens.map { $0 as Any } ?? NSNull(),
            "completion_tokens": response.completionTokens.map { $0 as Any } ?? NSNull(),
            "finish_reason": NSNull(),
          ]
        ]
      )
    case .retrieve(let query, let limit):
      eventSink?(.stageStarted(.ground))
      guard let grounding else {
        return try failureJSON(
          requestID: command.requestID,
          failure: "grounding",
          message: "The Rust core requested grounding, but no grounding provider is configured."
        )
      }
      let sources = try await grounding.search(query, limit: limit)
      let encodedSources: [[String: Any]] = sources.map { source in
        ["id": source.id, "path": source.path, "text": source.text, "score": source.score]
      }
      return try eventJSON(
        kind: "retrieval_completed",
        requestID: command.requestID,
        values: ["sources": encodedSources]
      )
    case .searchMemory(let query, let scope, let limit):
      eventSink?(.stageStarted(.ground))
      guard let memory else {
        return try failureJSON(
          requestID: command.requestID,
          failure: "memory",
          message: "The Rust core requested memory, but no memory store is configured."
        )
      }
      let records = try await memory.search(query, scope: scope, limit: limit)
      return try eventJSON(
        kind: "memory_search_completed",
        requestID: command.requestID,
        values: ["records": try records.map(memoryJSONObject)]
      )
    case .validateOutput(let output):
      eventSink?(.stageStarted(.validate))
      guard let validateOutput else {
        return try failureJSON(
          requestID: command.requestID,
          failure: "provider",
          message: "The Rust core requested application validation, but no validator is configured."
        )
      }
      return try eventJSON(
        kind: "output_validated",
        requestID: command.requestID,
        values: ["errors": validateOutput(output)]
      )
    case .loadSession(let sessionID, let limit):
      guard let sessionArtifacts else {
        return try failureJSON(
          requestID: command.requestID,
          failure: "session",
          message: "The Rust core requested session artifacts, but no provider is configured."
        )
      }
      let artifacts = try await sessionArtifacts.load(sessionID: sessionID, limit: limit)
      return try eventJSON(
        kind: "session_loaded",
        requestID: command.requestID,
        values: ["artifacts": try artifacts.map(jsonObject)]
      )
    case .prepareSkill(let skillID, let partialArguments, let artifacts):
      guard let skillHost else {
        return try failureJSON(
          requestID: command.requestID,
          failure: "skill",
          message: "The Rust core requested skill preparation, but no skill host is configured."
        )
      }
      eventSink?(.skillStarted(id: skillID))
      let outcome = try await skillHost.prepare(
        OperonSkillPreparationRequest(
          skillID: skillID,
          partialArguments: partialArguments,
          artifacts: artifacts
        ))
      return try eventJSON(
        kind: "skill_prepared",
        requestID: command.requestID,
        values: ["outcome": try preparationObject(outcome)]
      )
    case .invokeSkill(
      let skillID, let arguments, let idempotencyKey, let requiresUserConfirmation):
      guard let skillHost else {
        return try failureJSON(
          requestID: command.requestID,
          failure: "skill",
          message: "The Rust core requested a skill, but no skill host is configured."
        )
      }
      eventSink?(.skillStarted(id: skillID))
      let result = try await skillHost.invoke(
        OperonSkillInvocationRequest(
          skillID: skillID,
          arguments: arguments,
          idempotencyKey: idempotencyKey,
          requiresUserConfirmation: requiresUserConfirmation
        ))
      eventSink?(.skillCompleted(id: skillID))
      return try eventJSON(
        kind: "skill_completed",
        requestID: command.requestID,
        values: ["result": try jsonObject(result)]
      )
    }
  }

  private func sessionConfigJSON(
    outputSchema: [String: Any]?,
    hasApplicationValidator: Bool,
    memoryScope: OperonMemoryScope?
  ) throws -> String {
    let policy: [String: Any] = [
      "local_only": true,
      "planning": self.policy.planning.rawValue,
      "verification": "adaptive",
      "max_repair_attempts": self.policy.maximumRepairAttempts,
      "max_context_chars": self.policy.maximumContextCharacters,
      "max_sources": self.policy.maximumSources,
      "request_timeout_ms": self.policy.requestTimeoutMilliseconds,
      "max_replans": self.policy.maximumReplans,
      "require_skill_or_clarification": self.policy.requireSkillOrClarification,
      "grounding_mode": self.policy.groundingMode.rawValue,
      "validation_failure": self.policy.validationFailure.rawValue,
      "min_evidence_quote_chars": self.policy.minimumEvidenceQuoteCharacters,
    ]
    var config: [String: Any] = [
      "policy": policy,
      "has_grounding": grounding != nil,
      "has_application_validator": hasApplicationValidator,
      "max_session_artifacts": 12,
    ]
    if let outputSchema {
      config["output_schema"] = outputSchema
    }
    if let memoryScope {
      config["memory_scope"] = try memoryJSONObject(memoryScope)
    }
    if let sessionID {
      config["session_id"] = sessionID
    }
    if let completion {
      config["completion"] = try jsonObject(completion)
    }
    if let skillHost {
      config["skills"] = skillHost.descriptors.map { descriptor in
        [
          "id": descriptor.id,
          "description": descriptor.description,
          "input_schema": jsonSchema(from: descriptor.inputSchema),
          "output_schema": jsonSchema(from: descriptor.outputSchema),
          "consumes": descriptor.consumes,
          "produces": descriptor.produces,
          "requires_user_confirmation": descriptor.requiresUserConfirmation,
        ] as [String: Any]
      }
    }
    return try stringify(config)
  }

  private func eventJSON(
    kind: String,
    requestID: Int,
    values: [String: Any]
  ) throws -> String {
    var event = values
    event["kind"] = kind
    event["protocol_version"] = "0.3"
    event["request_id"] = requestID
    return try stringify(event)
  }

  private func failureJSON(
    requestID: Int,
    failure: String,
    message: String
  ) throws -> String {
    try eventJSON(
      kind: "command_failed",
      requestID: requestID,
      values: ["failure": failure, "message": message]
    )
  }
}

private func performanceSample(
  kind: OperonPerformanceSample.Kind,
  stage: OperonTraceEvent.Stage?,
  started: ContinuousClock.Instant,
  promptTokens: Int?,
  completionTokens: Int?
) -> OperonPerformanceSample {
  let components = started.duration(to: ContinuousClock.now).components
  let elapsed =
    Double(components.seconds) * 1_000
    + Double(components.attoseconds) / 1_000_000_000_000_000
  let process = ProcessInfo.processInfo
  let thermalState: OperonPerformanceSample.ThermalState =
    switch process.thermalState {
    case .nominal: .nominal
    case .fair: .fair
    case .serious: .serious
    case .critical: .critical
    @unknown default: .unknown
    }
  return OperonPerformanceSample(
    kind: kind,
    stage: stage,
    elapsedMilliseconds: elapsed,
    promptTokens: promptTokens,
    completionTokens: completionTokens,
    thermalState: thermalState,
    lowPowerModeEnabled: process.isLowPowerModeEnabled
  )
}

public struct OperonCoreCompletedResult: Sendable, Equatable {
  /// The terminal `{"kind":"complete","result":...}` ABI envelope.
  public let json: String

  public init(json: String) {
    self.json = json
  }

  public func status() throws -> OperonCoreRunStatus {
    try JSONDecoder().decode(CoreTerminalEnvelope.self, from: Data(json.utf8)).result.status
  }
}

private enum CoreCommandKind {
  case generate(stage: OperonTraceEvent.Stage)
  case retrieve(query: String, limit: Int)
  case searchMemory(query: String, scope: OperonMemoryScope, limit: Int)
  case validateOutput(Any)
  case loadSession(sessionID: String, limit: Int)
  case prepareSkill(
    skillID: String,
    partialArguments: OperonJSONValue,
    artifacts: [OperonArtifactReference]
  )
  case invokeSkill(
    skillID: String,
    arguments: OperonJSONValue,
    idempotencyKey: String,
    requiresUserConfirmation: Bool
  )
}

private struct CoreCommand {
  let requestID: Int
  let kind: CoreCommandKind
  let messages: [OperonMessage]
  let schema: JSONSchema
  let temperature: Double
  let maximumResponseTokens: Int?

  var stage: OperonTraceEvent.Stage {
    if case .generate(let stage) = kind { return stage }
    switch kind {
    case .retrieve, .searchMemory, .loadSession: return .ground
    case .prepareSkill, .invokeSkill: return .skill
    case .validateOutput: return .validate
    case .generate: return .generate
    }
  }

  var failureKind: String {
    switch kind {
    case .generate: return "provider"
    case .retrieve: return "grounding"
    case .searchMemory: return "memory"
    case .validateOutput: return "provider"
    case .loadSession: return "session"
    case .prepareSkill, .invokeSkill: return "skill"
    }
  }

  static func requestID(from json: String) -> Int? {
    guard
      let root = try? dictionary(from: json),
      let command = root["command"] as? [String: Any]
    else { return nil }
    return command["request_id"] as? Int
  }

  static func decode(_ json: String) throws -> Self {
    let root = try dictionary(from: json)
    guard root["kind"] as? String == "command",
      let command = root["command"] as? [String: Any],
      let kind = command["kind"] as? String,
      let requestID = command["request_id"] as? Int
    else {
      throw OperonCoreError.invalidResponse("Operon core returned an invalid command envelope.")
    }

    switch kind {
    case "generate":
      guard let request = command["request"] as? [String: Any],
        let rawMessages = request["messages"] as? [[String: Any]],
        let rawSchema = request["schema"] as? [String: Any]
      else {
        throw OperonCoreError.invalidResponse("Generate command is missing its request.")
      }
      let messages = try rawMessages.map { message in
        guard let role = message["role"] as? String,
          let content = message["content"] as? String,
          let operonRole = OperonMessage.Role(rawValue: role)
        else {
          throw OperonCoreError.invalidResponse("Generate command contains an invalid message.")
        }
        return OperonMessage(role: operonRole, content: content)
      }
      guard let temperature = request["temperature"] as? Double,
        let rawStage = command["stage"] as? String,
        let stage = OperonTraceEvent.Stage(rawValue: rawStage)
      else {
        throw OperonCoreError.invalidResponse("Generate command is missing temperature.")
      }
      return Self(
        requestID: requestID,
        kind: .generate(stage: stage),
        messages: messages,
        schema: try JSONSchema(object: rawSchema),
        temperature: temperature,
        maximumResponseTokens: request["max_tokens"] as? Int
      )
    case "retrieve":
      guard let query = command["query"] as? String, let limit = command["limit"] as? Int else {
        throw OperonCoreError.invalidResponse("Retrieve command is missing query or limit.")
      }
      return Self(
        requestID: requestID,
        kind: .retrieve(query: query, limit: limit),
        messages: [],
        schema: .string,
        temperature: 0,
        maximumResponseTokens: nil
      )
    case "search_memory":
      guard let query = command["query"] as? String,
        let rawScope = command["scope"] as? [String: Any],
        let limit = command["limit"] as? Int
      else {
        throw OperonCoreError.invalidResponse("Memory command is missing query, scope, or limit.")
      }
      let scope = try decodeMemoryScope(rawScope)
      return Self(
        requestID: requestID,
        kind: .searchMemory(query: query, scope: scope, limit: limit),
        messages: [],
        schema: .string,
        temperature: 0,
        maximumResponseTokens: nil
      )
    case "validate_output":
      guard let output = command["output"] else {
        throw OperonCoreError.invalidResponse("Validate output command is missing output.")
      }
      return Self(
        requestID: requestID,
        kind: .validateOutput(output),
        messages: [],
        schema: .string,
        temperature: 0,
        maximumResponseTokens: nil
      )
    case "load_session":
      guard let sessionID = command["session_id"] as? String,
        let limit = command["limit"] as? Int
      else {
        throw OperonCoreError.invalidResponse("Load session command is incomplete.")
      }
      return Self(
        requestID: requestID,
        kind: .loadSession(sessionID: sessionID, limit: limit),
        messages: [], schema: .string, temperature: 0, maximumResponseTokens: nil)
    case "prepare_skill":
      guard let skillID = command["skill_id"] as? String,
        let partialArguments = command["partial_arguments"],
        let rawArtifacts = command["artifacts"] as? [[String: Any]]
      else {
        throw OperonCoreError.invalidResponse("Prepare skill command is incomplete.")
      }
      let artifacts = try rawArtifacts.map { artifact in
        guard let id = artifact["id"] as? String,
          let kind = artifact["kind"] as? String,
          let summary = artifact["summary"] as? String
        else {
          throw OperonCoreError.invalidResponse("Prepare skill artifact is invalid.")
        }
        return OperonArtifactReference(id: id, kind: kind, summary: summary)
      }
      return Self(
        requestID: requestID,
        kind: .prepareSkill(
          skillID: skillID,
          partialArguments: try operonJSONValue(from: partialArguments),
          artifacts: artifacts),
        messages: [], schema: .string, temperature: 0, maximumResponseTokens: nil)
    case "invoke_skill":
      guard let skillID = command["skill_id"] as? String,
        let arguments = command["arguments"],
        let idempotencyKey = command["idempotency_key"] as? String,
        let requiresUserConfirmation = command["requires_user_confirmation"] as? Bool
      else {
        throw OperonCoreError.invalidResponse("Invoke skill command is incomplete.")
      }
      return Self(
        requestID: requestID,
        kind: .invokeSkill(
          skillID: skillID,
          arguments: try operonJSONValue(from: arguments),
          idempotencyKey: idempotencyKey,
          requiresUserConfirmation: requiresUserConfirmation),
        messages: [], schema: .string, temperature: 0, maximumResponseTokens: nil)
    default:
      throw OperonCoreError.invalidResponse("Operon core returned unknown command kind '\(kind)'.")
    }
  }
}

/// Internal rather than file-private so the naming invariant below can be
/// asserted directly. The conversion is where inlined `$defs` become plain
/// nested objects, and it is worth testing at that seam rather than only
/// through a live model.
indirect enum JSONSchema {
  case object(properties: [(String, JSONSchema, Bool)])
  case array(JSONSchema, minimumItems: Int?, maximumItems: Int?)
  case string
  case stringChoices([String])
  case number(minimum: Double?, maximum: Double?)
  case integer(minimum: Int?, maximum: Int?)
  case boolean

  init(object: [String: Any]) throws {
    try self.init(object: object, root: object, references: [])
  }

  private init(
    object: [String: Any],
    root: [String: Any],
    references: Set<String>
  ) throws {
    if let reference = object["$ref"] as? String {
      guard !references.contains(reference) else {
        throw OperonCoreError.invalidResponse("Generation schema contains a cyclic reference.")
      }
      guard let target = resolveSchemaReference(reference, root: root) else {
        throw OperonCoreError.invalidResponse(
          "Generation schema references unknown definition '\(reference)'.")
      }
      try self.init(
        object: target, root: root, references: references.union([reference]))
      return
    }
    guard let type = object["type"] as? String else {
      throw OperonCoreError.invalidResponse("Generation schema is missing a type.")
    }
    switch type {
    case "object":
      let required = Set(object["required"] as? [String] ?? [])
      let rawProperties = object["properties"] as? [String: [String: Any]] ?? [:]
      let properties = try rawProperties.keys.sorted().map { name in
        guard let property = rawProperties[name] else {
          throw OperonCoreError.invalidResponse("Object schema property is missing.")
        }
        return (
          name,
          try JSONSchema(object: property, root: root, references: references),
          !required.contains(name)
        )
      }
      self = .object(properties: properties)
    case "array":
      guard let items = object["items"] as? [String: Any] else {
        throw OperonCoreError.invalidResponse("Array schema is missing items.")
      }
      self = .array(
        try JSONSchema(object: items, root: root, references: references),
        minimumItems: object["minItems"] as? Int,
        maximumItems: object["maxItems"] as? Int)
    case "string":
      if let choices = object["enum"] as? [String] {
        self = .stringChoices(choices)
      } else {
        self = .string
      }
    case "number":
      self = .number(minimum: object["minimum"] as? Double, maximum: object["maximum"] as? Double)
    case "integer":
      self = .integer(minimum: object["minimum"] as? Int, maximum: object["maximum"] as? Int)
    case "boolean": self = .boolean
    default:
      throw OperonCoreError.invalidResponse("Unsupported generation schema type '\(type)'.")
    }
  }

  /// Every object in the tree needs a name that is unique within the tree.
  ///
  /// `$ref` is inlined during decoding, so a schema with `$defs` arrives here
  /// as a plain nested structure. Naming every object the same thing then
  /// produces several structurally different types sharing one identifier,
  /// and a provider that keys generated types by name — `DynamicGenerationSchema`
  /// does — cannot tell them apart. The extractive answer schema is the case
  /// that exposed it: root, `claim` and `evidence` are three distinct objects,
  /// and all three were called `OperonCoreResponse`.
  ///
  /// Citation mode has exactly one object and so never collided, which is why
  /// this survived: the mode with nested objects is the one without provider
  /// coverage.
  func operonSchema(path: String = "OperonCoreResponse") throws -> OperonSchema {
    switch self {
    case .object(let properties):
      return .object(
        name: path,
        properties: try properties.map { name, schema, optional in
          .init(
            name,
            schema: try schema.operonSchema(path: path + "_" + name),
            isOptional: optional)
        }
      )
    case .array(let items, let minimumItems, let maximumItems):
      return .array(
        items: try items.operonSchema(path: path + "_Item"),
        minimumItems: minimumItems,
        maximumItems: maximumItems)
    case .string: return .string()
    case .stringChoices(let choices): return .string(choices: choices)
    case .number(let minimum, let maximum): return .number(minimum: minimum, maximum: maximum)
    case .integer(let minimum, let maximum): return .integer(minimum: minimum, maximum: maximum)
    case .boolean: return .boolean()
    }
  }
}

private func resolveSchemaReference(
  _ reference: String,
  root: [String: Any]
) -> [String: Any]? {
  guard reference.hasPrefix("#/") else { return nil }
  var current: Any = root
  for rawToken in reference.dropFirst(2).split(separator: "/") {
    let token = rawToken.replacingOccurrences(of: "~1", with: "/")
      .replacingOccurrences(of: "~0", with: "~")
    guard let object = current as? [String: Any], let next = object[token] else { return nil }
    current = next
  }
  return current as? [String: Any]
}

private func dictionary(from json: String) throws -> [String: Any] {
  guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
  else {
    throw OperonCoreError.invalidResponse("Operon core returned a non-object JSON envelope.")
  }
  return object
}

private func stringify(_ object: [String: Any]) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
  guard
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
      as? [String: Any]
  else {
    throw OperonCoreError.invalidResponse("Value could not encode as a JSON object.")
  }
  return object
}

private func jsonValueObject(_ value: OperonJSONValue) throws -> Any {
  try JSONSerialization.jsonObject(
    with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
}

private func operonJSONValue(from value: Any) throws -> OperonJSONValue {
  try JSONDecoder().decode(
    OperonJSONValue.self,
    from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
  )
}

private func preparationObject(_ preparation: OperonSkillPreparation) throws -> [String: Any] {
  switch preparation {
  case .ready(let arguments):
    return ["kind": "ready", "arguments": try jsonValueObject(arguments)]
  case .needsInput(let clarification):
    return ["kind": "needs_input", "clarification": try jsonObject(clarification)]
  case .rejected(let reason):
    return ["kind": "rejected", "reason": reason]
  case .unavailable(let reason):
    return ["kind": "unavailable", "reason": reason]
  }
}

private func memoryJSONObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
  guard
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
      as? [String: Any]
  else {
    throw OperonCoreError.invalidResponse("Memory value could not encode as a JSON object.")
  }
  return object
}

private func decodeMemoryScope(_ value: [String: Any]) throws -> OperonMemoryScope {
  try JSONDecoder().decode(
    OperonMemoryScope.self,
    from: JSONSerialization.data(withJSONObject: value)
  )
}

private struct CoreTerminalEnvelope: Decodable {
  let kind: String
  let result: CoreTerminalResult
}

private struct CoreTerminalResult: Decodable {
  let status: OperonCoreRunStatus
  let answer: String
  let output: JSONValue
  let sources: [OperonSource]
  let confidence: Double
  let plan: OperonPlan
  let trace: [CoreTraceEvent]
  let wasRepaired: Bool
  let clarification: OperonClarification?
  let abstention: OperonAbstention?
  let cancellation: OperonCancellation?
  let claims: [OperonGroundedClaim]

  enum CodingKeys: String, CodingKey {
    case status, answer, output, sources, confidence, plan, trace
    case clarification, abstention, cancellation, claims
    case wasRepaired = "was_repaired"
  }
}

private struct CoreTraceEvent: Decodable {
  let stage: OperonTraceEvent.Stage
  let message: String
  let elapsedMilliseconds: Double

  enum CodingKeys: String, CodingKey {
    case stage, message
    case elapsedMilliseconds = "elapsed_ms"
  }
}

private struct JSONValue: Decodable {
  let value: Any

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      value = NSNull()
    } else if let bool = try? container.decode(Bool.self) {
      value = bool
    } else if let number = try? container.decode(Double.self) {
      value = number
    } else if let string = try? container.decode(String.self) {
      value = string
    } else if let array = try? container.decode([JSONValue].self) {
      value = array.map(\.value)
    } else {
      value = try container.decode([String: JSONValue].self).mapValues(\.value)
    }
  }
}

private func decodeTerminalOutcome<Output: Codable & Sendable>(
  _ json: String,
  outputType: Output.Type
) throws -> OperonRunOutcome<Output> {
  let envelope = try JSONDecoder().decode(CoreTerminalEnvelope.self, from: Data(json.utf8))
  guard envelope.kind == "complete" else {
    throw OperonCoreError.invalidResponse("Operon core returned a non-terminal result envelope.")
  }
  switch envelope.result.status {
  case .completed:
    let outputData = try JSONSerialization.data(
      withJSONObject: envelope.result.output.value,
      options: [.fragmentsAllowed]
    )
    let output = try JSONDecoder().decode(Output.self, from: outputData)
    return .completed(
      OperonResult(
        answer: envelope.result.answer,
        output: output,
        confidence: envelope.result.confidence,
        sources: envelope.result.sources,
        plan: envelope.result.plan,
        trace: envelope.result.trace.map {
          OperonTraceEvent(
            stage: $0.stage,
            message: $0.message,
            elapsedMilliseconds: $0.elapsedMilliseconds
          )
        },
        wasRepaired: envelope.result.wasRepaired,
        claims: envelope.result.claims
      ))
  case .clarification:
    guard let clarification = envelope.result.clarification else {
      throw OperonCoreError.invalidResponse("Clarification result omitted its details.")
    }
    return .clarification(clarification)
  case .abstained:
    guard let abstention = envelope.result.abstention else {
      throw OperonCoreError.invalidResponse("Abstention result omitted its details.")
    }
    return .abstained(abstention)
  case .cancelled:
    guard let cancellation = envelope.result.cancellation else {
      throw OperonCoreError.invalidResponse("Cancellation result omitted its details.")
    }
    return .cancelled(cancellation)
  }
}

private func jsonSchema(from schema: OperonSchema) -> [String: Any] {
  switch schema {
  case .object(_, let description, let properties):
    var value: [String: Any] = [
      "type": "object",
      "properties": Dictionary(
        uniqueKeysWithValues: properties.map { ($0.name, jsonSchema(from: $0.schema)) }
      ),
      "required": properties.filter { !$0.isOptional }.map(\.name),
      "additionalProperties": false,
    ]
    if let description { value["description"] = description }
    return value
  case .array(let items, let minimumItems, let maximumItems):
    var value: [String: Any] = ["type": "array", "items": jsonSchema(from: items)]
    if let minimumItems { value["minItems"] = minimumItems }
    if let maximumItems { value["maxItems"] = maximumItems }
    return value
  case .string(let description, let choices):
    var value: [String: Any] = ["type": "string"]
    if let description { value["description"] = description }
    if let choices { value["enum"] = choices }
    return value
  case .number(let description, let minimum, let maximum):
    var value: [String: Any] = ["type": "number"]
    if let description { value["description"] = description }
    if let minimum { value["minimum"] = minimum }
    if let maximum { value["maximum"] = maximum }
    return value
  case .integer(let description, let minimum, let maximum):
    var value: [String: Any] = ["type": "integer"]
    if let description { value["description"] = description }
    if let minimum { value["minimum"] = minimum }
    if let maximum { value["maximum"] = maximum }
    return value
  case .boolean(let description):
    var value: [String: Any] = ["type": "boolean"]
    if let description { value["description"] = description }
    return value
  case .reference(let name):
    return ["$ref": "#/$defs/\(name)"]
  case .definitions(let root, let values):
    var value = jsonSchema(from: root)
    value["$defs"] = Dictionary(
      uniqueKeysWithValues: values.map { ($0.key, jsonSchema(from: $0.value)) })
    return value
  }
}
