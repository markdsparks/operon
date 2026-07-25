import Foundation
import FoundationModels
import OperonKit

@available(iOS 26.0, macOS 26.0, *)
public struct AppleFoundationModelsProvider: OperonModelProvider {
  private let model: SystemLanguageModel

  public init(model: SystemLanguageModel = .default) {
    self.model = model
  }

  public func availability() async -> OperonAvailability {
    switch model.availability {
    case .available:
      .available
    case .unavailable(let reason):
      .unavailable(reason: availabilityReason(reason))
    }
  }

  public func generate(
    _ request: OperonGenerationRequest
  ) async throws -> OperonGenerationResponse {
    guard case .available = model.availability else {
      if case .unavailable(let reason) = model.availability {
        throw OperonError.modelUnavailable(availabilityReason(reason))
      }
      throw OperonError.modelUnavailable("unknown")
    }

    let instructions = request.messages
      .filter { $0.role == .system }
      .map(\.content)
      .joined(separator: "\n\n")
    let prompt = request.messages
      .filter { $0.role != .system }
      .map { "\($0.role.rawValue.uppercased()):\n\($0.content)" }
      .joined(separator: "\n\n")
    let session = LanguageModelSession(
      model: model,
      tools: [],
      instructions: instructions
    )
    let schema = try generationSchema(from: request.schema)
    let options = GenerationOptions(
      temperature: request.temperature,
      maximumResponseTokens: request.maximumResponseTokens
    )
    let response = try await session.respond(
      to: prompt,
      schema: schema,
      includeSchemaInPrompt: true,
      options: options
    )
    return OperonGenerationResponse(text: response.content.jsonString)
  }

  public func generateStreaming(
    _ request: OperonGenerationRequest,
    onUpdate: @escaping @Sendable (String) -> Void
  ) async throws -> OperonGenerationResponse {
    guard case .available = model.availability else {
      if case .unavailable(let reason) = model.availability {
        throw OperonError.modelUnavailable(availabilityReason(reason))
      }
      throw OperonError.modelUnavailable("unknown")
    }
    let instructions = request.messages
      .filter { $0.role == .system }
      .map(\.content)
      .joined(separator: "\n\n")
    let prompt = request.messages
      .filter { $0.role != .system }
      .map { "\($0.role.rawValue.uppercased()):\n\($0.content)" }
      .joined(separator: "\n\n")
    let session = LanguageModelSession(model: model, tools: [], instructions: instructions)
    let stream = session.streamResponse(
      to: prompt,
      schema: try generationSchema(from: request.schema),
      includeSchemaInPrompt: true,
      options: GenerationOptions(
        temperature: request.temperature,
        maximumResponseTokens: request.maximumResponseTokens)
    )
    var latest = ""
    for try await snapshot in stream {
      try Task.checkCancellation()
      latest = snapshot.rawContent.jsonString
      onUpdate(latest)
    }
    guard !latest.isEmpty else {
      throw OperonError.provider("Apple Foundation Models returned no streamed response.")
    }
    return OperonGenerationResponse(text: latest)
  }
}

@available(iOS 26.0, macOS 26.0, *)
private func generationSchema(from schema: OperonSchema) throws -> GenerationSchema {
  if case .definitions(let root, let values) = schema {
    return try GenerationSchema(
      root: dynamicSchema(from: root, path: "Root"),
      dependencies: values.keys.sorted().map { name in
        dynamicSchema(from: values[name]!, path: name)
      })
  }
  return try GenerationSchema(root: dynamicSchema(from: schema, path: "Root"), dependencies: [])
}

@available(iOS 26.0, macOS 26.0, *)
private func dynamicSchema(
  from schema: OperonSchema,
  path: String
) -> DynamicGenerationSchema {
  switch schema {
  case .object(let name, let description, let properties):
    return DynamicGenerationSchema(
      name: name,
      description: description,
      properties: properties.map { property in
        DynamicGenerationSchema.Property(
          name: property.name,
          description: property.description,
          schema: dynamicSchema(
            from: property.schema,
            path: path + "_" + property.name
          ),
          isOptional: property.isOptional
        )
      }
    )
  case .array(let items, let minimumItems, let maximumItems):
    return DynamicGenerationSchema(
      arrayOf: dynamicSchema(from: items, path: path + "_Item"),
      minimumElements: minimumItems,
      maximumElements: maximumItems
    )
  case .string(_, let choices):
    if let choices {
      return DynamicGenerationSchema(
        name: sanitized(path) + "Choice",
        anyOf: choices
      )
    }
    return DynamicGenerationSchema(type: String.self)
  case .number(_, let minimum, let maximum):
    var guides: [GenerationGuide<Double>] = []
    if let minimum { guides.append(.minimum(minimum)) }
    if let maximum { guides.append(.maximum(maximum)) }
    return DynamicGenerationSchema(type: Double.self, guides: guides)
  case .integer(_, let minimum, let maximum):
    var guides: [GenerationGuide<Int>] = []
    if let minimum { guides.append(.minimum(minimum)) }
    if let maximum { guides.append(.maximum(maximum)) }
    return DynamicGenerationSchema(type: Int.self, guides: guides)
  case .boolean:
    return DynamicGenerationSchema(type: Bool.self)
  case .reference(let name):
    return DynamicGenerationSchema(referenceTo: name)
  case .definitions(let root, _):
    return dynamicSchema(from: root, path: path)
  }
}

private func sanitized(_ value: String) -> String {
  value.filter { $0.isLetter || $0.isNumber || $0 == "_" }
}

@available(iOS 26.0, macOS 26.0, *)
private func availabilityReason(
  _ reason: SystemLanguageModel.Availability.UnavailableReason
) -> String {
  switch reason {
  case .deviceNotEligible:
    "device_not_eligible"
  case .appleIntelligenceNotEnabled:
    "apple_intelligence_not_enabled"
  case .modelNotReady:
    "model_not_ready"
  @unknown default:
    "unknown"
  }
}
