import Foundation
import OperonKit

#if canImport(MLXLLM)
  import MLX
  import MLXLLM
  import MLXLMCommon
  import MLXLMHuggingFace
  // swift-transformers' `Tokenizer` protocol predates Sendable auditing —
  // its own loaded instances are read-only after construction in practice,
  // but the protocol itself carries no such guarantee the compiler can see.
  // `@preconcurrency` accepts that on trust rather than papering over it
  // with `@unchecked Sendable` at the point of use below.
  @preconcurrency import Tokenizers

  // A model provider independent of Apple's FoundationModels framework —
  // no iOS 26 floor, no Apple Intelligence eligibility, no system-model
  // availability check. This exists because the spike
  // (github.com/markdsparks/mellon, spikes/operon-ios/FINDINGS.md) measured
  // the ~3B on-device tier Apple ships today as a hard capability ceiling
  // for extractive grounding: it recognised the right evidence in 13 of 18
  // trials and still answered "no evidence" in 11 of those, and never once
  // produced a verified verbatim quote across 12 configurations. GroundBench
  // 0.3's Qwen3 4B run showed the opposite failure shape — 100% exact-quote
  // fidelity under Operon's own validation, 41.7% safe refusal versus 0% raw
  // — which is the evidence spec 021 said to wait for before re-opening L2.
  //
  // Gated on RAM rather than OS version or Apple Intelligence enrollment,
  // because the constraint is genuinely the model's resident footprint, not
  // anything Apple-specific. A 4-bit ~4B model needs roughly 2.5-3.5GB
  // resident; iOS's jetsam budget scales with total device RAM (~4GB
  // foreground budget on an 8GB device, ~900MB on 3GB) — comfortable on a
  // 12GB-class device, tight to the point of risk on an 8GB one once the
  // host app's own footprint shares the same budget. `recommendedMinimumRAMBytes`
  // is a starting point, not a measured cutoff — the Mellon spike is what
  // turns this into a real number.
  //
  // No native structured generation here (raw MLX inference has no
  // guided-decoding hook comparable to Apple's `DynamicGenerationSchema`).
  // `renderSchemaInstructions` embeds the JSON Schema as text in the
  // system prompt instead — the same thing `AppleFoundationModelsProvider`
  // ALSO does via `includeSchemaInPrompt: true`, on top of guided decoding,
  // so a text-included schema is already known to help, not just a fallback
  // theory. Operon's own JSON parse + schema validation + bounded repair
  // loop (crates/operon-core) is the safety net for whatever the model
  // fails to get exactly right — this provider does not need to reproduce
  // that logic, only feed it plausible JSON.
  //
  // `MLXGuidedGeneration` (this package, xgrammar-backed, iOS 17+, no
  // FoundationModels coupling) is the natural upgrade once this ships:
  // real grammar-constrained decoding instead of a hopeful prompt. Left for
  // a follow-up rather than this first cut, to keep the surface small
  // enough to actually validate.
  public actor MLXModelProvider: OperonModelProvider {
    /// Below this, a 4-bit ~4B model's resident footprint risks the app's
    /// own jetsam budget on an 8GB-class device. Revisit once the Mellon
    /// spike has a real on-device number rather than the arithmetic above.
    public static let recommendedMinimumRAMBytes: UInt64 = 12_000_000_000

    private let modelId: String
    private let revision: String
    private let minimumRAMBytes: UInt64

    private var container: ModelContainer?
    private var loadError: Error?

    public init(
      modelId: String = "mlx-community/Qwen3.5-4B-4bit",
      revision: String = "main",
      minimumRAMBytes: UInt64 = MLXModelProvider.recommendedMinimumRAMBytes
    ) {
      self.modelId = modelId
      self.revision = revision
      self.minimumRAMBytes = minimumRAMBytes
    }

    public func availability() async -> OperonAvailability {
      guard ProcessInfo.processInfo.physicalMemory >= minimumRAMBytes else {
        return .unavailable(reason: "device_ram_below_recommended")
      }
      if let loadError {
        return .unavailable(reason: "model_load_failed: \(loadError.localizedDescription)")
      }
      return .available
    }

    private func loadedContainer() async throws -> ModelContainer {
      if let container { return container }
      do {
        let configuration = ModelConfiguration(id: modelId, revision: revision)
        let loaded = try await LLMModelFactory.shared.loadContainer(
          from: HubClient.default,
          using: OperonTokenizerLoader(),
          configuration: configuration
        )
        container = loaded
        return loaded
      } catch {
        loadError = error
        throw error
      }
    }

    public func generate(
      _ request: OperonGenerationRequest
    ) async throws -> OperonGenerationResponse {
      let container = try await loadedContainer()
      let session = chatSession(container, for: request)
      let text = try await session.respond(to: mlxMessages(from: request))
      guard !text.isEmpty else {
        throw OperonError.provider("MLX model returned an empty response.")
      }
      return OperonGenerationResponse(text: text)
    }

    public func generateStreaming(
      _ request: OperonGenerationRequest,
      onUpdate: @escaping @Sendable (String) -> Void
    ) async throws -> OperonGenerationResponse {
      let container = try await loadedContainer()
      let session = chatSession(container, for: request)
      var latest = ""
      for try await chunk in session.streamResponse(to: mlxMessages(from: request)) {
        try Task.checkCancellation()
        latest += chunk
        onUpdate(latest)
      }
      guard !latest.isEmpty else {
        throw OperonError.provider("MLX model returned no streamed response.")
      }
      return OperonGenerationResponse(text: latest)
    }

    // `nonisolated`: touches none of the actor's stored state, and being
    // actor-isolated here is exactly what made the compiler treat the
    // returned `ChatSession` as unsafe to hand to a nonisolated `respond`
    // call — `ChatSession` isn't `Sendable`, so a value actor-isolated at
    // its creation cannot cross that boundary safely. Not being isolated in
    // the first place is the correct fix, not a workaround.
    private nonisolated func chatSession(
      _ container: ModelContainer,
      for request: OperonGenerationRequest
    ) -> ChatSession {
      let systemContent = request.messages
        .filter { $0.role == .system }
        .map(\.content)
        .joined(separator: "\n\n")
      let instructions = [systemContent, renderSchemaInstructions(request.schema)]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
      return ChatSession(
        container,
        instructions: instructions.isEmpty ? nil : instructions,
        generateParameters: GenerateParameters(
          maxTokens: request.maximumResponseTokens,
          temperature: Float(request.temperature)
        )
      )
    }
  }

  private func mlxMessages(from request: OperonGenerationRequest) -> [Chat.Message] {
    request.messages
      .filter { $0.role != .system }
      .map { message in
        switch message.role {
        case .user: .user(message.content)
        case .assistant: .assistant(message.content)
        case .system: .system(message.content)
        }
      }
  }

  /// A text rendering of `OperonSchema`, appended to the system prompt.
  /// There is no native guided decoding on this path, so this is the only
  /// signal the model receives about the expected output shape — Operon's
  /// own validation/repair loop covers whatever it gets wrong.
  func renderSchemaInstructions(_ schema: OperonSchema) -> String {
    var lines = [
      "Respond with a single JSON value matching exactly this schema. Do not",
      "include markdown fences or any text outside the JSON value.",
      "",
    ]
    lines.append(schemaLine(schema, indent: 0))
    return lines.joined(separator: "\n")
  }

  private func schemaLine(_ schema: OperonSchema, indent: Int) -> String {
    let pad = String(repeating: "  ", count: indent)
    switch schema {
    case .object(let name, let description, let properties):
      var out = "\(pad)\(name) (object)"
      if let description { out += " — \(description)" }
      for property in properties {
        out += "\n\(pad)  \"\(property.name)\"\(property.isOptional ? " (optional)" : "")"
        if let d = property.description { out += " — \(d)" }
        out += ":\n" + schemaLine(property.schema, indent: indent + 2)
      }
      return out
    case .array(let items, let minimumItems, let maximumItems):
      var out = "\(pad)array of:\n" + schemaLine(items, indent: indent + 1)
      if minimumItems != nil || maximumItems != nil {
        out += "\n\(pad)(count: \(minimumItems.map(String.init) ?? "0")-\(maximumItems.map(String.init) ?? "unbounded"))"
      }
      return out
    case .string(let description, let choices):
      var out = "\(pad)string"
      if let choices { out += " — one of: \(choices.joined(separator: ", "))" }
      if let description { out += " — \(description)" }
      return out
    case .number(let description, let minimum, let maximum):
      var out = "\(pad)number"
      if let minimum { out += " (min \(minimum))" }
      if let maximum { out += " (max \(maximum))" }
      if let description { out += " — \(description)" }
      return out
    case .integer(let description, let minimum, let maximum):
      var out = "\(pad)integer"
      if let minimum { out += " (min \(minimum))" }
      if let maximum { out += " (max \(maximum))" }
      if let description { out += " — \(description)" }
      return out
    case .boolean(let description):
      var out = "\(pad)boolean"
      if let description { out += " — \(description)" }
      return out
    case .reference(let name):
      return "\(pad)<\(name)>"
    case .definitions(let root, let values):
      var out = schemaLine(root, indent: indent)
      for name in values.keys.sorted() {
        out += "\n\(pad)where \(name) is:\n" + schemaLine(values[name]!, indent: indent + 1)
      }
      return out
    }
  }

  /// Bridges `swift-transformers`' tokenizer (canonical, actively
  /// maintained by Hugging Face) to `MLXLMCommon`'s smaller `Tokenizer`
  /// protocol. Deliberately not the community `MLXLMTokenizers` package —
  /// as of this writing its own dependency is a branch reference to a
  /// forked `mlx-swift-lm` that no longer exists on GitHub ("Repository
  /// not found"), so it cannot resolve. This adapter is the whole
  /// difference: both sides define `Message` as the same
  /// `[String: any Sendable]` shape, so chat-template application passes
  /// straight through with no reshaping.
  private struct OperonTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
      OperonTokenizerAdapter(wrapped: try await AutoTokenizer.from(modelFolder: directory))
    }
  }

  private struct OperonTokenizerAdapter: MLXLMCommon.Tokenizer {
    let wrapped: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
      wrapped.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
      wrapped.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
      wrapped.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
      wrapped.convertIdToToken(id)
    }

    var bosToken: String? { wrapped.bosToken }
    var eosToken: String? { wrapped.eosToken }
    var unknownToken: String? { wrapped.unknownToken }

    func applyChatTemplate(
      messages: [[String: any Sendable]],
      tools: [[String: any Sendable]]?,
      additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
      try wrapped.applyChatTemplate(
        messages: messages,
        tools: tools,
        additionalContext: additionalContext
      )
    }
  }
#endif
