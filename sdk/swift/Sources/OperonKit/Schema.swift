import Foundation

public struct OperonSchemaProperty: Sendable {
  public let name: String
  public let description: String?
  public let schema: OperonSchema
  public let isOptional: Bool

  public init(
    _ name: String,
    description: String? = nil,
    schema: OperonSchema,
    isOptional: Bool = false
  ) {
    self.name = name
    self.description = description
    self.schema = schema
    self.isOptional = isOptional
  }
}

public indirect enum OperonSchema: Sendable {
  case object(name: String, description: String? = nil, properties: [OperonSchemaProperty])
  case array(items: OperonSchema)
  case string(description: String? = nil, choices: [String]? = nil)
  case number(description: String? = nil, minimum: Double? = nil, maximum: Double? = nil)
  case integer(description: String? = nil, minimum: Int? = nil, maximum: Int? = nil)
  case boolean(description: String? = nil)
}

extension OperonSchema {
  static let plan: OperonSchema = .object(
    name: "OperonPlan",
    properties: [
      .init("intent", schema: .string()),
      .init("subquestions", schema: .array(items: .string())),
      .init("needs_grounding", schema: .boolean()),
      .init("answer_requirements", schema: .array(items: .string())),
    ]
  )

  static func answer(output: OperonSchema) -> OperonSchema {
    .object(
      name: "OperonAnswer",
      properties: [
        .init("answer", schema: .string()),
        .init(
          "confidence",
          description: "A number from zero to one.",
          schema: .number(minimum: 0, maximum: 1)
        ),
        .init("used_source_ids", schema: .array(items: .string())),
        .init("output", schema: output),
      ]
    )
  }

  func validationErrors(for value: Any, path: String = "output") -> [String] {
    switch self {
    case .object(_, _, let properties):
      guard let object = value as? [String: Any] else {
        return ["\(path) must be an object"]
      }
      var errors: [String] = []
      let allowed = Set(properties.map(\.name))
      for name in object.keys where !allowed.contains(name) {
        errors.append("\(path).\(name) is not allowed")
      }
      for property in properties {
        guard let child = object[property.name] else {
          if !property.isOptional {
            errors.append("\(path).\(property.name) is required")
          }
          continue
        }
        errors.append(
          contentsOf: property.schema.validationErrors(
            for: child,
            path: "\(path).\(property.name)"
          )
        )
      }
      return errors
    case .array(let items):
      guard let array = value as? [Any] else {
        return ["\(path) must be an array"]
      }
      return array.enumerated().flatMap { index, item in
        items.validationErrors(for: item, path: "\(path)[\(index)]")
      }
    case .string(_, let choices):
      guard let string = value as? String else {
        return ["\(path) must be a string"]
      }
      if let choices, !choices.contains(string) {
        return ["\(path) must be one of \(choices.joined(separator: ", "))"]
      }
      return []
    case .number(_, let minimum, let maximum):
      guard !(value is Bool), let number = value as? NSNumber else {
        return ["\(path) must be a number"]
      }
      return numericBounds(number.doubleValue, minimum: minimum, maximum: maximum, path: path)
    case .integer(_, let minimum, let maximum):
      guard !(value is Bool), let number = value as? NSNumber else {
        return ["\(path) must be an integer"]
      }
      let double = number.doubleValue
      guard double.rounded() == double else {
        return ["\(path) must be an integer"]
      }
      return numericBounds(
        double,
        minimum: minimum.map(Double.init),
        maximum: maximum.map(Double.init),
        path: path
      )
    case .boolean:
      return value is Bool ? [] : ["\(path) must be a boolean"]
    }
  }
}

private func numericBounds(
  _ value: Double,
  minimum: Double?,
  maximum: Double?,
  path: String
) -> [String] {
  var errors: [String] = []
  if let minimum, value < minimum {
    errors.append("\(path) must be at least \(minimum)")
  }
  if let maximum, value > maximum {
    errors.append("\(path) must be at most \(maximum)")
  }
  return errors
}
