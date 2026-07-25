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
  /// Produces cumulative provisional structured output. The final return value
  /// is the only output Operon validates and may present as authoritative.
  func generateStreaming(
    _ request: OperonGenerationRequest,
    onUpdate: @escaping @Sendable (String) -> Void
  ) async throws -> OperonGenerationResponse
}

extension OperonModelProvider {
  public func generateStreaming(
    _ request: OperonGenerationRequest,
    onUpdate: @escaping @Sendable (String) -> Void
  ) async throws -> OperonGenerationResponse {
    let response = try await generate(request)
    onUpdate(response.text)
    return response
  }
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

  public enum GroundingMode: String, Sendable, Codable {
    case citation
    case extractive
  }

  public enum ValidationFailure: String, Sendable, Codable {
    case abstain
    case error
  }

  public var planning: Planning
  public var maximumSources: Int
  public var maximumContextCharacters: Int
  public var maximumRepairAttempts: Int
  public var maximumReplans: Int
  public var requireSkillOrClarification: Bool
  public var groundingMode: GroundingMode
  public var validationFailure: ValidationFailure
  public var minimumEvidenceQuoteCharacters: Int
  public var requestTimeoutMilliseconds: Int

  public init(
    planning: Planning = .adaptive,
    maximumSources: Int = 5,
    maximumContextCharacters: Int = 12_000,
    maximumRepairAttempts: Int = 1,
    maximumReplans: Int = 2,
    requireSkillOrClarification: Bool = false,
    groundingMode: GroundingMode = .citation,
    validationFailure: ValidationFailure = .abstain,
    minimumEvidenceQuoteCharacters: Int = 12,
    requestTimeoutMilliseconds: Int = 60_000
  ) {
    precondition(maximumSources > 0)
    precondition(maximumContextCharacters > 0)
    precondition(maximumRepairAttempts >= 0)
    precondition(maximumReplans >= 0)
    precondition(minimumEvidenceQuoteCharacters > 0)
    precondition(requestTimeoutMilliseconds > 0)
    self.planning = planning
    self.maximumSources = maximumSources
    self.maximumContextCharacters = maximumContextCharacters
    self.maximumRepairAttempts = maximumRepairAttempts
    self.maximumReplans = maximumReplans
    self.requireSkillOrClarification = requireSkillOrClarification
    self.groundingMode = groundingMode
    self.validationFailure = validationFailure
    self.minimumEvidenceQuoteCharacters = minimumEvidenceQuoteCharacters
    self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
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
    case replan
    case skill
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

public struct OperonEvidenceQuote: Sendable, Codable, Equatable {
  public let sourceID: String
  public let quote: String
  public let startByte: Int?
  public let endByte: Int?

  enum CodingKeys: String, CodingKey {
    case quote
    case sourceID = "source_id"
    case startByte = "start_byte"
    case endByte = "end_byte"
  }
}

public struct OperonGroundedClaim: Sendable, Codable, Equatable {
  public let text: String
  public let evidence: [OperonEvidenceQuote]
}

public struct OperonClarification: Sendable, Codable, Equatable {
  public let prompt: String
  public let missingFields: [String]
  public let skillID: String?

  public init(prompt: String, missingFields: [String] = [], skillID: String? = nil) {
    self.prompt = prompt
    self.missingFields = missingFields
    self.skillID = skillID
  }

  enum CodingKeys: String, CodingKey {
    case prompt
    case missingFields = "missing_fields"
    case skillID = "skill_id"
  }
}

public struct OperonAbstention: Sendable, Codable, Equatable {
  public let reason: String
  public let unsupportedClaims: [String]

  public init(reason: String, unsupportedClaims: [String] = []) {
    self.reason = reason
    self.unsupportedClaims = unsupportedClaims
  }

  enum CodingKeys: String, CodingKey {
    case reason
    case unsupportedClaims = "unsupported_claims"
  }
}

public struct OperonCancellation: Sendable, Codable, Equatable {
  public let reason: String

  public init(reason: String) { self.reason = reason }
}

public enum OperonRunOutcome<Output: Sendable>: Sendable {
  case completed(OperonResult<Output>)
  case clarification(OperonClarification)
  case abstained(OperonAbstention)
  case cancelled(OperonCancellation)
}

public enum OperonRunEvent: Sendable, Equatable {
  case stageStarted(OperonTraceEvent.Stage)
  case provisionalModelOutput(stage: OperonTraceEvent.Stage, text: String)
  case skillStarted(id: String)
  case skillCompleted(id: String)
  case measurement(OperonPerformanceSample)
  case finished(OperonCoreRunStatus)
}

public struct OperonPerformanceSample: Sendable, Codable, Equatable {
  public enum Kind: String, Sendable, Codable {
    case modelCall
    case run
  }

  public enum ThermalState: String, Sendable, Codable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
  }

  public let kind: Kind
  public let stage: OperonTraceEvent.Stage?
  public let elapsedMilliseconds: Double
  public let promptTokens: Int?
  public let completionTokens: Int?
  public let thermalState: ThermalState
  public let lowPowerModeEnabled: Bool

  public init(
    kind: Kind,
    stage: OperonTraceEvent.Stage? = nil,
    elapsedMilliseconds: Double,
    promptTokens: Int? = nil,
    completionTokens: Int? = nil,
    thermalState: ThermalState,
    lowPowerModeEnabled: Bool
  ) {
    self.kind = kind
    self.stage = stage
    self.elapsedMilliseconds = elapsedMilliseconds
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.thermalState = thermalState
    self.lowPowerModeEnabled = lowPowerModeEnabled
  }
}

public enum OperonCoreRunStatus: String, Sendable, Codable, Equatable {
  case completed
  case clarification
  case abstained
  case cancelled
}

public struct OperonResult<Output: Sendable>: Sendable {
  public let answer: String
  public let output: Output
  public let confidence: Double
  public let sources: [OperonSource]
  public let plan: OperonPlan
  public let trace: [OperonTraceEvent]
  public let wasRepaired: Bool
  public let claims: [OperonGroundedClaim]

  public init(
    answer: String,
    output: Output,
    confidence: Double,
    sources: [OperonSource],
    plan: OperonPlan,
    trace: [OperonTraceEvent],
    wasRepaired: Bool,
    claims: [OperonGroundedClaim] = []
  ) {
    self.answer = answer
    self.output = output
    self.confidence = confidence
    self.sources = sources
    self.plan = plan
    self.trace = trace
    self.wasRepaired = wasRepaired
    self.claims = claims
  }
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
