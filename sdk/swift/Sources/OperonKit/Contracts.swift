import Foundation

public enum OperonAvailability: Sendable, Equatable {
  case available
  case unavailable(reason: String)
}

public struct OperonMessage: Sendable, Codable, Equatable {
  public enum Role: String, Sendable, Codable {
    case system
    case user
    case assistant
  }

  public let role: Role
  public let content: String

  public init(role: Role, content: String) {
    self.role = role
    self.content = content
  }
}

public struct OperonGenerationRequest: Sendable {
  public let messages: [OperonMessage]
  public let schema: OperonSchema
  public let temperature: Double
  public let maximumResponseTokens: Int?

  public init(
    messages: [OperonMessage],
    schema: OperonSchema,
    temperature: Double = 0.1,
    maximumResponseTokens: Int? = nil
  ) {
    self.messages = messages
    self.schema = schema
    self.temperature = temperature
    self.maximumResponseTokens = maximumResponseTokens
  }
}

public struct OperonGenerationResponse: Sendable, Equatable {
  public let text: String
  public let promptTokens: Int?
  public let completionTokens: Int?

  public init(
    text: String,
    promptTokens: Int? = nil,
    completionTokens: Int? = nil
  ) {
    self.text = text
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
  }
}

public protocol OperonModelProvider: Sendable {
  func availability() async -> OperonAvailability
  func generate(_ request: OperonGenerationRequest) async throws -> OperonGenerationResponse
}

public struct OperonSource: Sendable, Codable, Equatable {
  public let id: String
  public let path: String
  public let text: String
  public let score: Double

  public init(id: String, path: String, text: String, score: Double = 1) {
    self.id = id
    self.path = path
    self.text = text
    self.score = score
  }
}

public protocol OperonGroundingProvider: Sendable {
  func search(_ query: String, limit: Int) async throws -> [OperonSource]
}

public struct OperonPolicy: Sendable, Equatable {
  public enum Planning: String, Sendable, Codable {
    case always
    case adaptive
    case never
  }

  public var planning: Planning
  public var maximumSources: Int
  public var maximumContextCharacters: Int
  public var maximumRepairAttempts: Int

  public init(
    planning: Planning = .adaptive,
    maximumSources: Int = 5,
    maximumContextCharacters: Int = 12_000,
    maximumRepairAttempts: Int = 1
  ) {
    precondition(maximumSources > 0)
    precondition(maximumContextCharacters > 0)
    precondition(maximumRepairAttempts >= 0)
    self.planning = planning
    self.maximumSources = maximumSources
    self.maximumContextCharacters = maximumContextCharacters
    self.maximumRepairAttempts = maximumRepairAttempts
  }
}

public struct OperonPlan: Sendable, Codable, Equatable {
  public let intent: String
  public let subquestions: [String]
  public let needsGrounding: Bool
  public let answerRequirements: [String]

  public init(
    intent: String,
    subquestions: [String],
    needsGrounding: Bool,
    answerRequirements: [String]
  ) {
    self.intent = intent
    self.subquestions = subquestions
    self.needsGrounding = needsGrounding
    self.answerRequirements = answerRequirements
  }

  enum CodingKeys: String, CodingKey {
    case intent
    case subquestions
    case needsGrounding = "needs_grounding"
    case answerRequirements = "answer_requirements"
  }
}

public struct OperonTraceEvent: Sendable, Codable, Equatable {
  public enum Stage: String, Sendable, Codable {
    case classify
    case ground
    case generate
    case validate
    case repair
  }

  public let stage: Stage
  public let message: String
  public let elapsedMilliseconds: Double

  public init(stage: Stage, message: String, elapsedMilliseconds: Double) {
    self.stage = stage
    self.message = message
    self.elapsedMilliseconds = elapsedMilliseconds
  }
}

public struct OperonResult<Output: Sendable>: Sendable {
  public let answer: String
  public let output: Output
  public let confidence: Double
  public let sources: [OperonSource]
  public let plan: OperonPlan
  public let trace: [OperonTraceEvent]
  public let wasRepaired: Bool
}

public enum OperonError: Error, Sendable, LocalizedError, Equatable {
  case modelUnavailable(String)
  case invalidModelOutput([String])
  case provider(String)

  public var errorDescription: String? {
    switch self {
    case .modelUnavailable(let reason):
      "The selected on-device model is unavailable: \(reason)"
    case .invalidModelOutput(let errors):
      "The model output failed validation: \(errors.joined(separator: "; "))"
    case .provider(let message):
      "The model provider failed: \(message)"
    }
  }
}
