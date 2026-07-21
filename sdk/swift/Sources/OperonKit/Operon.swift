import Foundation

public struct Operon: Sendable {
  private let model: any OperonModelProvider
  private let grounding: (any OperonGroundingProvider)?
  private let policy: OperonPolicy

  public init(
    model: any OperonModelProvider,
    grounding: (any OperonGroundingProvider)? = nil,
    policy: OperonPolicy = .init()
  ) {
    self.model = model
    self.grounding = grounding
    self.policy = policy
  }

  public func run<Output: Codable & Sendable>(
    _ query: String,
    outputSchema: OperonSchema,
    as outputType: Output.Type = Output.self,
    validateOutput: (@Sendable (Output) -> [String])? = nil
  ) async throws -> OperonResult<Output> {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      throw OperonError.invalidModelOutput(["query cannot be empty"])
    }
    let availability = await model.availability()
    guard case .available = availability else {
      if case .unavailable(let reason) = availability {
        throw OperonError.modelUnavailable(reason)
      }
      throw OperonError.modelUnavailable("unknown")
    }

    let clock = ContinuousClock()
    let started = clock.now
    var trace: [OperonTraceEvent] = []
    let plan = try await makePlan(query, started: started, trace: &trace)
    let sources = try await retrieve(query, plan: plan, started: started, trace: &trace)
    let answerSchema = OperonSchema.answer(output: outputSchema)
    var candidate = try await generateAnswer(
      query,
      plan: plan,
      sources: sources,
      schema: answerSchema,
      started: started,
      trace: &trace
    )
    var wasRepaired = false
    var validation = validate(
      candidate,
      sources: sources,
      outputType: outputType,
      outputSchema: outputSchema,
      validateOutput: validateOutput
    )
    trace.append(event(.validate, "validated candidate answer", started, clock))

    if !validation.errors.isEmpty,
      let normalized = normalizeCitations(candidate, sources: sources)
    {
      candidate = normalized
      wasRepaired = true
      trace.append(event(.repair, "normalized valid source citations", started, clock))
      validation = validate(
        candidate,
        sources: sources,
        outputType: outputType,
        outputSchema: outputSchema,
        validateOutput: validateOutput
      )
      trace.append(event(.validate, "validated deterministic repair", started, clock))
    }

    var attempts = 0
    while !validation.errors.isEmpty && attempts < policy.maximumRepairAttempts {
      candidate = try await repair(
        query,
        plan: plan,
        sources: sources,
        candidate: candidate,
        errors: validation.errors,
        schema: answerSchema,
        started: started,
        trace: &trace
      )
      attempts += 1
      wasRepaired = true
      if let normalized = normalizeCitations(candidate, sources: sources) {
        candidate = normalized
        trace.append(event(.repair, "normalized repaired citations", started, clock))
      }
      validation = validate(
        candidate,
        sources: sources,
        outputType: outputType,
        outputSchema: outputSchema,
        validateOutput: validateOutput
      )
      trace.append(event(.validate, "validated repaired answer", started, clock))
    }

    guard validation.errors.isEmpty, let envelope = validation.envelope else {
      throw OperonError.invalidModelOutput(validation.errors)
    }
    let used = Set(envelope.usedSourceIDs)
    return OperonResult(
      answer: envelope.answer,
      output: envelope.output,
      confidence: envelope.confidence,
      sources: sources.filter { used.contains($0.id) },
      plan: plan,
      trace: trace,
      wasRepaired: wasRepaired
    )
  }

  private func makePlan(
    _ query: String,
    started: ContinuousClock.Instant,
    trace: inout [OperonTraceEvent]
  ) async throws -> OperonPlan {
    let shouldPlan =
      policy.planning == .always
      || (policy.planning == .adaptive && Self.isComplex(query))
    guard shouldPlan else {
      trace.append(event(.classify, "used fast-path plan", started, ContinuousClock()))
      return OperonPlan(
        intent: query,
        subquestions: [],
        needsGrounding: grounding != nil,
        answerRequirements: []
      )
    }
    let response = try await model.generate(
      OperonGenerationRequest(
        messages: [
          .init(
            role: .system,
            content: "Decompose the task only when useful. Return the requested structure."
          ),
          .init(role: .user, content: query),
        ],
        schema: .plan,
        temperature: 0,
        maximumResponseTokens: 500
      )
    )
    var plan = try decode(OperonPlan.self, from: response.text)
    // Attached grounding is an application contract, not a model choice.
    plan = OperonPlan(
      intent: plan.intent,
      subquestions: plan.subquestions,
      needsGrounding: grounding != nil,
      answerRequirements: plan.answerRequirements
    )
    trace.append(event(.classify, "model produced task plan", started, ContinuousClock()))
    return plan
  }

  private func retrieve(
    _ query: String,
    plan: OperonPlan,
    started: ContinuousClock.Instant,
    trace: inout [OperonTraceEvent]
  ) async throws -> [OperonSource] {
    guard let grounding else {
      trace.append(event(.ground, "grounding not configured", started, ContinuousClock()))
      return []
    }
    let retrievalQuery = ([query, plan.intent] + plan.subquestions).joined(separator: "\n")
    let sources = try await grounding.search(retrievalQuery, limit: policy.maximumSources)
    trace.append(event(.ground, "retrieved local context", started, ContinuousClock()))
    return sources
  }

  private func generateAnswer(
    _ query: String,
    plan: OperonPlan,
    sources: [OperonSource],
    schema: OperonSchema,
    started: ContinuousClock.Instant,
    trace: inout [OperonTraceEvent]
  ) async throws -> String {
    let prompt = """
      QUERY:
      \(query)

      PLAN:
      \(try jsonString(plan))

      LOCAL SOURCES:
      \(formattedSources(sources))
      """
    let response = try await model.generate(
      OperonGenerationRequest(
        messages: [
          .init(
            role: .system,
            content: "Use only supplied sources for app-specific facts. Cite used sources as [S1]."
          ),
          .init(role: .user, content: prompt),
        ],
        schema: schema
      )
    )
    trace.append(event(.generate, "generated candidate answer", started, ContinuousClock()))
    return response.text
  }

  private func repair(
    _ query: String,
    plan: OperonPlan,
    sources: [OperonSource],
    candidate: String,
    errors: [String],
    schema: OperonSchema,
    started: ContinuousClock.Instant,
    trace: inout [OperonTraceEvent]
  ) async throws -> String {
    let response = try await model.generate(
      OperonGenerationRequest(
        messages: [
          .init(
            role: .system,
            content: "Repair the candidate to satisfy every error using only supplied evidence."
          ),
          .init(
            role: .user,
            content:
              "QUERY:\n\(query)\n\nPLAN:\n\(try jsonString(plan))\n\nSOURCES:\n\(formattedSources(sources))\n\nCANDIDATE:\n\(candidate)\n\nERRORS:\n\(errors.joined(separator: "\n"))"
          ),
        ],
        schema: schema,
        temperature: 0
      )
    )
    trace.append(event(.repair, "requested targeted repair", started, ContinuousClock()))
    return response.text
  }

  private func validate<Output: Codable & Sendable>(
    _ candidate: String,
    sources: [OperonSource],
    outputType: Output.Type,
    outputSchema: OperonSchema,
    validateOutput: (@Sendable (Output) -> [String])?
  ) -> Validation<Output> {
    do {
      let envelope = try decode(AnswerEnvelope<Output>.self, from: candidate)
      var errors: [String] = []
      if envelope.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        errors.append("answer must not be empty")
      }
      if !(0...1).contains(envelope.confidence) {
        errors.append("confidence must be between zero and one")
      }
      let valid = Set(sources.map(\.id))
      let used = Set(envelope.usedSourceIDs)
      if !used.isSubset(of: valid) {
        errors.append("used_source_ids contains an unknown source")
      }
      if !sources.isEmpty && used.isEmpty {
        errors.append("a grounded answer must declare evidence")
      }
      let cited = Self.citations(in: envelope.answer)
      if cited != used {
        errors.append("inline citations must match used_source_ids")
      }
      if let root = try? JSONSerialization.jsonObject(
        with: Data(cleanJSON(candidate).utf8)
      ) as? [String: Any], let rawOutput = root["output"] {
        errors.append(contentsOf: outputSchema.validationErrors(for: rawOutput))
      } else {
        errors.append("output is required")
      }
      if let validateOutput {
        errors.append(contentsOf: validateOutput(envelope.output))
      }
      return Validation(envelope: envelope, errors: errors)
    } catch {
      return Validation(envelope: nil, errors: ["invalid structured output: \(error)"])
    }
  }

  private func normalizeCitations(_ candidate: String, sources: [OperonSource]) -> String? {
    guard
      var object = try? JSONSerialization.jsonObject(with: Data(cleanJSON(candidate).utf8))
        as? [String: Any],
      var answer = object["answer"] as? String,
      let used = object["used_source_ids"] as? [String],
      !used.isEmpty
    else { return nil }
    let valid = Set(sources.map(\.id))
    let usedSet = Set(used)
    let cited = Self.citations(in: answer)
    guard usedSet.isSubset(of: valid), cited.isSubset(of: usedSet) else { return nil }
    let missing = used.filter { !cited.contains($0) }
    guard !missing.isEmpty else { return nil }
    answer += " " + missing.map { "[\($0)]" }.joined(separator: " ")
    object["answer"] = answer
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else {
      return nil
    }
    return String(decoding: data, as: UTF8.self)
  }

  private func formattedSources(_ sources: [OperonSource]) -> String {
    var remaining = policy.maximumContextCharacters
    var sections: [String] = []
    for source in sources {
      let header = "[\(source.id)] \(source.path)\n"
      guard header.count < remaining else { break }
      let available = remaining - header.count
      let text = String(source.text.prefix(available))
      sections.append(header + text)
      remaining -= min(remaining, header.count + text.count + 2)
    }
    return sections.isEmpty ? "(none)" : sections.joined(separator: "\n\n")
  }

  private static func isComplex(_ query: String) -> Bool {
    let lowered = query.lowercased()
    let markers = ["compare", "analyze", "evaluate", "plan", "why", "steps", "based on"]
    return query.split(separator: " ").count >= 18 || markers.contains { lowered.contains($0) }
  }

  private static func citations(in answer: String) -> Set<String> {
    let expression = try? NSRegularExpression(pattern: #"\[(S\d+)\]"#)
    let range = NSRange(answer.startIndex..., in: answer)
    return Set(
      (expression?.matches(in: answer, range: range) ?? []).compactMap { match in
        guard let range = Range(match.range(at: 1), in: answer) else { return nil }
        return String(answer[range])
      })
  }
}

private struct AnswerEnvelope<Output: Codable & Sendable>: Codable, Sendable {
  let answer: String
  let confidence: Double
  let usedSourceIDs: [String]
  let output: Output

  enum CodingKeys: String, CodingKey {
    case answer
    case confidence
    case usedSourceIDs = "used_source_ids"
    case output
  }
}

private struct Validation<Output: Codable & Sendable> {
  let envelope: AnswerEnvelope<Output>?
  let errors: [String]
}

private func decode<Value: Decodable>(_ type: Value.Type, from text: String) throws -> Value {
  try JSONDecoder().decode(type, from: Data(cleanJSON(text).utf8))
}

private func cleanJSON(_ text: String) -> String {
  var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
  if value.hasPrefix("```") {
    value = value.replacingOccurrences(
      of: #"^```(?:json)?\s*|\s*```$"#,
      with: "",
      options: .regularExpression
    )
  }
  if let start = value.firstIndex(of: "{"), let end = value.lastIndex(of: "}") {
    return String(value[start...end])
  }
  return value
}

private func jsonString<Value: Encodable>(_ value: Value) throws -> String {
  String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

private func event(
  _ stage: OperonTraceEvent.Stage,
  _ message: String,
  _ started: ContinuousClock.Instant,
  _ clock: ContinuousClock
) -> OperonTraceEvent {
  let duration = started.duration(to: clock.now)
  let components = duration.components
  let milliseconds =
    Double(components.seconds) * 1_000
    + Double(components.attoseconds) / 1_000_000_000_000_000
  return OperonTraceEvent(
    stage: stage,
    message: message,
    elapsedMilliseconds: milliseconds
  )
}
