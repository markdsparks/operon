import Foundation

/// Sendable JSON used at the app-owned skill and session boundaries.
public indirect enum OperonJSONValue: Sendable, Codable, Equatable {
  case object([String: OperonJSONValue])
  case array([OperonJSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([OperonJSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: OperonJSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

public struct OperonSessionArtifact: Sendable, Codable, Equatable {
  public let id: String
  public let kind: String
  public let summary: String
  public let value: OperonJSONValue
  public let turnID: String?
  public let expiresAt: String?

  public init(
    id: String,
    kind: String,
    summary: String,
    value: OperonJSONValue,
    turnID: String? = nil,
    expiresAt: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.summary = summary
    self.value = value
    self.turnID = turnID
    self.expiresAt = expiresAt
  }

  enum CodingKeys: String, CodingKey {
    case id, kind, summary, value
    case turnID = "turn_id"
    case expiresAt = "expires_at"
  }
}

public protocol OperonSessionArtifactProvider: Sendable {
  func load(sessionID: String, limit: Int) async throws -> [OperonSessionArtifact]
}

public struct OperonArtifactReference: Sendable, Codable, Equatable {
  public let id: String
  public let kind: String
  public let summary: String

  public init(id: String, kind: String, summary: String) {
    self.id = id
    self.kind = kind
    self.summary = summary
  }
}

public struct OperonSkillDescriptor: Sendable {
  public let id: String
  public let description: String
  public let inputSchema: OperonSchema
  public let outputSchema: OperonSchema
  public let consumes: [String]
  public let produces: [String]
  public let requiresUserConfirmation: Bool

  public init(
    id: String,
    description: String,
    inputSchema: OperonSchema,
    outputSchema: OperonSchema,
    consumes: [String] = [],
    produces: [String] = [],
    requiresUserConfirmation: Bool = false
  ) {
    self.id = id
    self.description = description
    self.inputSchema = inputSchema
    self.outputSchema = outputSchema
    self.consumes = consumes
    self.produces = produces
    self.requiresUserConfirmation = requiresUserConfirmation
  }
}

public struct OperonSkillPreparationRequest: Sendable {
  public let skillID: String
  public let partialArguments: OperonJSONValue
  public let artifacts: [OperonArtifactReference]

  public init(
    skillID: String,
    partialArguments: OperonJSONValue,
    artifacts: [OperonArtifactReference]
  ) {
    self.skillID = skillID
    self.partialArguments = partialArguments
    self.artifacts = artifacts
  }
}

public enum OperonSkillPreparation: Sendable, Equatable {
  case ready(arguments: OperonJSONValue)
  case needsInput(OperonClarification)
  case rejected(reason: String)
  case unavailable(reason: String)
}

public struct OperonSkillInvocationRequest: Sendable {
  public let skillID: String
  public let arguments: OperonJSONValue
  public let idempotencyKey: String
  public let requiresUserConfirmation: Bool

  public init(
    skillID: String,
    arguments: OperonJSONValue,
    idempotencyKey: String,
    requiresUserConfirmation: Bool
  ) {
    self.skillID = skillID
    self.arguments = arguments
    self.idempotencyKey = idempotencyKey
    self.requiresUserConfirmation = requiresUserConfirmation
  }
}

public struct OperonSkillResult: Sendable, Codable, Equatable {
  public let output: OperonJSONValue
  public let sources: [OperonSource]
  public let artifacts: [OperonSessionArtifact]

  public init(
    output: OperonJSONValue,
    sources: [OperonSource] = [],
    artifacts: [OperonSessionArtifact] = []
  ) {
    self.output = output
    self.sources = sources
    self.artifacts = artifacts
  }
}

public protocol OperonSkillHost: Sendable {
  var descriptors: [OperonSkillDescriptor] { get }
  func prepare(_ request: OperonSkillPreparationRequest) async throws
    -> OperonSkillPreparation
  func invoke(_ request: OperonSkillInvocationRequest) async throws -> OperonSkillResult
}

public struct OperonCompletionContract: Sendable, Codable, Equatable {
  public let requiredSkillIDs: [String]
  public let requiredArtifactKinds: [String]

  public init(requiredSkillIDs: [String] = [], requiredArtifactKinds: [String] = []) {
    self.requiredSkillIDs = requiredSkillIDs
    self.requiredArtifactKinds = requiredArtifactKinds
  }

  enum CodingKeys: String, CodingKey {
    case requiredSkillIDs = "required_skill_ids"
    case requiredArtifactKinds = "required_artifact_kinds"
  }
}

public struct OperonSkillReceipt: Sendable, Codable, Equatable {
  public let idempotencyKey: String
  public let skillID: String
  public let artifactIDs: [String]
  public let artifactKinds: [String]

  enum CodingKeys: String, CodingKey {
    case idempotencyKey = "idempotency_key"
    case skillID = "skill_id"
    case artifactIDs = "artifact_ids"
    case artifactKinds = "artifact_kinds"
  }
}
