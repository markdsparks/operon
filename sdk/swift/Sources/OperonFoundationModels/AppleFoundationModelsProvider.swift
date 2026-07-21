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
}

@available(iOS 26.0, macOS 26.0, *)
private func generationSchema(from schema: OperonSchema) throws -> GenerationSchema {
  let root = dynamicSchema(from: schema, path: "Root")
  return try GenerationSchema(root: root, dependencies: [])
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
  case .array(let items):
    return DynamicGenerationSchema(
      arrayOf: dynamicSchema(from: items, path: path + "_Item")
    )
  case .string(_, let choices):
    if let choices {
      return DynamicGenerationSchema(
        name: sanitized(path) + "Choice",
        anyOf: choices
      )
    }
    return DynamicGenerationSchema(type: String.self)
  case .number:
    return DynamicGenerationSchema(type: Double.self)
  case .integer:
    return DynamicGenerationSchema(type: Int.self)
  case .boolean:
    return DynamicGenerationSchema(type: Bool.self)
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
