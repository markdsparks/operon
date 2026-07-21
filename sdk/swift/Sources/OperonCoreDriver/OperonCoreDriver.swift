import Foundation
import OperonCoreFFI
import OperonKit

/// Runs a complete Rust-core command/event session with app-owned local
/// inference and grounding providers.
///
/// The driver has no storage authority. A host may supply a local grounding
/// provider, and future memory commands will be routed to a separately scoped
/// application-owned memory provider.
public final class OperonCoreDriver {
  private let model: any OperonModelProvider
  private let grounding: (any OperonGroundingProvider)?
  private let memory: (any OperonMemoryStore)?
  private let memoryScope: OperonMemoryScope?
  private let policy: OperonPolicy

  public init(
    model: any OperonModelProvider,
    grounding: (any OperonGroundingProvider)? = nil,
    memory: (any OperonMemoryStore)? = nil,
    memoryScope: OperonMemoryScope? = nil,
    policy: OperonPolicy = .init()
  ) {
    self.model = model
    self.grounding = grounding
    self.memory = memory
    self.memoryScope = memoryScope
    self.policy = policy
  }

  /// Executes the core's command loop and returns its terminal protocol result.
  public func run(_ query: String) async throws -> OperonCoreCompletedResult {
    try await runSession(query, outputSchema: nil, validateOutput: nil)
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
  ) async throws -> OperonResult<Output> {
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
      }
    )
    return try decodeTerminalResult(result.json, outputType: outputType)
  }

  private func runSession(
    _ query: String,
    outputSchema: [String: Any]?,
    validateOutput: (@Sendable (Any) -> [String])?
  ) async throws -> OperonCoreCompletedResult {
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
        return OperonCoreCompletedResult(json: json)
      case .command(let json):
        let command = try CoreCommand.decode(json)
        let event: String
        do {
          event = try await execute(command, validateOutput: validateOutput)
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
    validateOutput: (@Sendable (Any) -> [String])?
  ) async throws -> String {
    switch command.kind {
    case .generate:
      let response = try await model.generate(
        OperonGenerationRequest(
          messages: command.messages,
          schema: try command.schema.operonSchema(),
          temperature: command.temperature,
          maximumResponseTokens: command.maximumResponseTokens
        )
      )
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
      "request_timeout_ms": 60_000,
    ]
    var config: [String: Any] = [
      "policy": policy,
      "has_grounding": grounding != nil,
      "has_application_validator": hasApplicationValidator,
    ]
    if let outputSchema {
      config["output_schema"] = outputSchema
    }
    if let memoryScope {
      config["memory_scope"] = try memoryJSONObject(memoryScope)
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
    event["protocol_version"] = "0.1"
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

public struct OperonCoreCompletedResult: Sendable, Equatable {
  /// The terminal `{"kind":"complete","result":...}` ABI envelope.
  public let json: String

  public init(json: String) {
    self.json = json
  }
}

private enum CoreCommandKind {
  case generate
  case retrieve(query: String, limit: Int)
  case searchMemory(query: String, scope: OperonMemoryScope, limit: Int)
  case validateOutput(Any)
}

private struct CoreCommand {
  let requestID: Int
  let kind: CoreCommandKind
  let messages: [OperonMessage]
  let schema: JSONSchema
  let temperature: Double
  let maximumResponseTokens: Int?

  var failureKind: String {
    switch kind {
    case .generate: return "provider"
    case .retrieve: return "grounding"
    case .searchMemory: return "memory"
    case .validateOutput: return "provider"
    }
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
      guard let temperature = request["temperature"] as? Double else {
        throw OperonCoreError.invalidResponse("Generate command is missing temperature.")
      }
      return Self(
        requestID: requestID,
        kind: .generate,
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
    default:
      throw OperonCoreError.invalidResponse("Operon core returned unknown command kind '\(kind)'.")
    }
  }
}

private indirect enum JSONSchema {
  case object(properties: [(String, JSONSchema, Bool)])
  case array(JSONSchema)
  case string
  case stringChoices([String])
  case number(minimum: Double?, maximum: Double?)
  case integer(minimum: Int?, maximum: Int?)
  case boolean

  init(object: [String: Any]) throws {
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
        return (name, try JSONSchema(object: property), !required.contains(name))
      }
      self = .object(properties: properties)
    case "array":
      guard let items = object["items"] as? [String: Any] else {
        throw OperonCoreError.invalidResponse("Array schema is missing items.")
      }
      self = .array(try JSONSchema(object: items))
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

  func operonSchema() throws -> OperonSchema {
    switch self {
    case .object(let properties):
      return .object(
        name: "OperonCoreResponse",
        properties: try properties.map { name, schema, optional in
          .init(name, schema: try schema.operonSchema(), isOptional: optional)
        }
      )
    case .array(let items): return .array(items: try items.operonSchema())
    case .string: return .string()
    case .stringChoices(let choices): return .string(choices: choices)
    case .number(let minimum, let maximum): return .number(minimum: minimum, maximum: maximum)
    case .integer(let minimum, let maximum): return .integer(minimum: minimum, maximum: maximum)
    case .boolean: return .boolean()
    }
  }
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
  let answer: String
  let output: JSONValue
  let sources: [OperonSource]
  let confidence: Double
  let plan: OperonPlan
  let trace: [CoreTraceEvent]
  let wasRepaired: Bool

  enum CodingKeys: String, CodingKey {
    case answer, output, sources, confidence, plan, trace
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

private func decodeTerminalResult<Output: Codable & Sendable>(
  _ json: String,
  outputType: Output.Type
) throws -> OperonResult<Output> {
  let envelope = try JSONDecoder().decode(CoreTerminalEnvelope.self, from: Data(json.utf8))
  guard envelope.kind == "complete" else {
    throw OperonCoreError.invalidResponse("Operon core returned a non-terminal result envelope.")
  }
  let outputData = try JSONSerialization.data(
    withJSONObject: envelope.result.output.value,
    options: [.fragmentsAllowed]
  )
  let output = try JSONDecoder().decode(Output.self, from: outputData)
  return OperonResult(
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
    wasRepaired: envelope.result.wasRepaired
  )
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
  case .array(let items):
    return ["type": "array", "items": jsonSchema(from: items)]
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
  }
}
