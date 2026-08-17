import OperonKit

/// The progressive public entry point for adding Operon to an existing model.
///
/// `automatic` deliberately keeps a plain model wrap on the one-call fast
/// path. Planning becomes available when the host attaches knowledge or live
/// state and becomes required when it attaches application skills. Advanced
/// hosts can still construct `OperonCoreDriver` directly.
public final class OperonRuntime: @unchecked Sendable {
  public enum Profile: Sendable, Equatable {
    /// Select the cheapest useful planning policy from attached capabilities.
    case automatic
    /// Never add a planning model call.
    case fast
    /// Plan only for requests the portable classifier considers complex.
    case grounded
    /// Always plan so app-owned skills can be selected and ordered.
    case agentic
  }

  public let providerCapabilities: OperonModelCapabilities
  public let policy: OperonPolicy

  private let driver: OperonCoreDriver

  /// Wraps the model already used by the app.
  ///
  /// With no optional capabilities attached, a valid response takes one model
  /// call: generation plus deterministic local validation. Grounding, memory,
  /// typed session state, and skills are progressively additive.
  public static func wrap(
    _ model: any OperonModelProvider,
    grounding: (any OperonGroundingProvider)? = nil,
    memory: (any OperonMemoryStore)? = nil,
    memoryScope: OperonMemoryScope? = nil,
    sessionArtifacts: (any OperonSessionArtifactProvider)? = nil,
    skillHost: (any OperonSkillHost)? = nil,
    sessionID: String? = nil,
    completion: OperonCompletionContract? = nil,
    profile: Profile = .automatic,
    policy explicitPolicy: OperonPolicy? = nil
  ) -> OperonRuntime {
    var policy = explicitPolicy ?? OperonPolicy()
    if explicitPolicy == nil {
      policy.planning = profile.planning(
        hasGrounding: grounding != nil,
        hasContinuity: memory != nil || (sessionArtifacts != nil && sessionID != nil),
        hasSkills: skillHost != nil || completion != nil
      )
    }
    return OperonRuntime(
      model: model,
      grounding: grounding,
      memory: memory,
      memoryScope: memoryScope,
      policy: policy,
      sessionArtifacts: sessionArtifacts,
      skillHost: skillHost,
      sessionID: sessionID,
      completion: completion
    )
  }

  private init(
    model: any OperonModelProvider,
    grounding: (any OperonGroundingProvider)?,
    memory: (any OperonMemoryStore)?,
    memoryScope: OperonMemoryScope?,
    policy: OperonPolicy,
    sessionArtifacts: (any OperonSessionArtifactProvider)?,
    skillHost: (any OperonSkillHost)?,
    sessionID: String?,
    completion: OperonCompletionContract?
  ) {
    providerCapabilities = model.capabilities
    self.policy = policy
    driver = OperonCoreDriver(
      model: model,
      grounding: grounding,
      memory: memory,
      memoryScope: memoryScope,
      policy: policy,
      sessionArtifacts: sessionArtifacts,
      skillHost: skillHost,
      sessionID: sessionID,
      completion: completion
    )
  }

  /// Runs a normal language turn and returns a readable, typed terminal result.
  public func ask(_ query: String) async throws -> OperonTurnResult {
    try await driver.run(query).turnResult()
  }

  /// Runs with an application-defined typed output and validation contract.
  public func run<Output: Codable & Sendable>(
    _ query: String,
    outputSchema: OperonSchema,
    as outputType: Output.Type = Output.self,
    validateOutput: (@Sendable (Output) -> [String])? = nil
  ) async throws -> OperonRunOutcome<Output> {
    try await driver.run(
      query,
      outputSchema: outputSchema,
      as: outputType,
      validateOutput: validateOutput
    )
  }

  /// Streams provisional updates while preserving the typed terminal envelope.
  public func stream(_ query: String) -> AsyncThrowingStream<OperonRunEvent, Error> {
    driver.stream(query)
  }
}

extension OperonRuntime.Profile {
  fileprivate func planning(
    hasGrounding: Bool,
    hasContinuity: Bool,
    hasSkills: Bool
  ) -> OperonPolicy.Planning {
    switch self {
    case .automatic:
      if hasSkills { return .always }
      if hasGrounding || hasContinuity { return .adaptive }
      return .never
    case .fast:
      return .never
    case .grounded:
      return .adaptive
    case .agentic:
      return .always
    }
  }
}

/// The complete terminal state for a normal `ask` call.
///
/// The common path is simply `result.answer`. Apps that need stronger control
/// can switch on `status`, inspect evidence and receipts, or render a structured
/// clarification/abstention without decoding protocol JSON.
public struct OperonTurnResult: Sendable, Equatable {
  public let status: OperonCoreRunStatus
  public let answer: String
  public let output: OperonJSONValue?
  public let confidence: Double
  public let sources: [OperonSource]
  public let plan: OperonPlan
  public let trace: [OperonTraceEvent]
  public let wasRepaired: Bool
  public let clarification: OperonClarification?
  public let abstention: OperonAbstention?
  public let cancellation: OperonCancellation?
  public let claims: [OperonGroundedClaim]
  public let skillReceipts: [OperonSkillReceipt]

  public init(
    status: OperonCoreRunStatus,
    answer: String,
    output: OperonJSONValue?,
    confidence: Double,
    sources: [OperonSource],
    plan: OperonPlan,
    trace: [OperonTraceEvent],
    wasRepaired: Bool,
    clarification: OperonClarification?,
    abstention: OperonAbstention?,
    cancellation: OperonCancellation?,
    claims: [OperonGroundedClaim],
    skillReceipts: [OperonSkillReceipt]
  ) {
    self.status = status
    self.answer = answer
    self.output = output
    self.confidence = confidence
    self.sources = sources
    self.plan = plan
    self.trace = trace
    self.wasRepaired = wasRepaired
    self.clarification = clarification
    self.abstention = abstention
    self.cancellation = cancellation
    self.claims = claims
    self.skillReceipts = skillReceipts
  }
}

extension OperonStreamCompletion {
  /// Decodes a stream's authoritative terminal event without rerunning it.
  public func turnResult() throws -> OperonTurnResult {
    try OperonCoreCompletedResult(json: json).turnResult()
  }
}
