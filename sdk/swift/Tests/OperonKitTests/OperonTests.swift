import Foundation
import Testing

@testable import OperonCoreDriver
@testable import OperonCoreFFI
@testable import OperonKit
@testable import OperonSQLite

private struct Decision: Codable, Sendable, Equatable {
  let decision: String
  let amount: Double
}

private actor ScriptedProvider: OperonModelProvider {
  private var responses: [String]
  private(set) var requestCount = 0
  private(set) var lastPrompt = ""

  init(_ responses: [String]) {
    self.responses = responses
  }

  func availability() async -> OperonAvailability {
    .available
  }

  func generate(_ request: OperonGenerationRequest) async throws -> OperonGenerationResponse {
    requestCount += 1
    lastPrompt = request.messages.map(\.content).joined(separator: "\n")
    guard !responses.isEmpty else {
      throw OperonError.provider("script exhausted")
    }
    return OperonGenerationResponse(text: responses.removeFirst())
  }
}

private actor RecordingGrounding: OperonGroundingProvider {
  private(set) var searches = 0

  func search(_ query: String, limit: Int) async throws -> [OperonSource] {
    searches += 1
    return [
      OperonSource(
        id: "S1",
        path: "policy.md",
        text: "The allowed amount is $68."
      )
    ]
  }
}

private actor RecordingSkillHost: OperonSkillHost {
  nonisolated let descriptors = [
    OperonSkillDescriptor(
      id: "calendar.create",
      description: "Create a calendar event",
      inputSchema: .object(
        name: "CreateEventInput",
        properties: [.init("title", schema: .string())]),
      outputSchema: .object(
        name: "CreateEventOutput",
        properties: [.init("event_id", schema: .string())])
    )
  ]
  private(set) var invocations = 0

  func prepare(_ request: OperonSkillPreparationRequest) async throws
    -> OperonSkillPreparation
  {
    .ready(arguments: request.partialArguments)
  }

  func invoke(_ request: OperonSkillInvocationRequest) async throws -> OperonSkillResult {
    invocations += 1
    return OperonSkillResult(output: .object(["event_id": .string("event-1")]))
  }
}

private let decisionSchema = OperonSchema.object(
  name: "Decision",
  properties: [
    .init("decision", schema: .string(choices: ["allow", "deny", "partial"])),
    .init("amount", schema: .number(minimum: 0)),
  ]
)

@Test
func groundedTypedOutputAndCitationNormalization() async throws {
  let provider = ScriptedProvider([
    #"{"answer":"The allowed amount is $68.","confidence":0.9,"used_source_ids":["S1"],"output":{"decision":"partial","amount":68}}"#
  ])
  let grounding = RecordingGrounding()
  let operon = Operon(
    model: provider,
    grounding: grounding,
    policy: OperonPolicy(planning: .never)
  )

  let result: OperonResult<Decision> = try await operon.run(
    "Determine the allowed amount.",
    outputSchema: decisionSchema
  )

  #expect(result.output == Decision(decision: "partial", amount: 68))
  #expect(result.answer.hasSuffix("[S1]"))
  #expect(result.wasRepaired)
  #expect(await provider.requestCount == 1)
  #expect(await grounding.searches == 1)
}

@Test
func plannerCannotVetoAttachedGrounding() async throws {
  let provider = ScriptedProvider([
    #"{"intent":"Decide","subquestions":[],"needs_grounding":false,"answer_requirements":[]}"#,
    #"{"answer":"Allowed [S1]","confidence":0.8,"used_source_ids":["S1"],"output":{"decision":"allow","amount":68}}"#,
  ])
  let grounding = RecordingGrounding()
  let operon = Operon(
    model: provider,
    grounding: grounding,
    policy: OperonPolicy(planning: .always)
  )

  let result: OperonResult<Decision> = try await operon.run(
    "Analyze whether this is allowed.",
    outputSchema: decisionSchema
  )

  #expect(result.plan.needsGrounding)
  #expect(await grounding.searches == 1)
  #expect(await provider.requestCount == 2)
}

@Test
func applicationValidatorTriggersTargetedRepair() async throws {
  let provider = ScriptedProvider([
    #"{"answer":"The amount is $48 [S1]","confidence":0.8,"used_source_ids":["S1"],"output":{"decision":"maybe","amount":48}}"#,
    #"{"answer":"The food subtotal is $68; alcohol is excluded [S1]","confidence":0.9,"used_source_ids":["S1"],"output":{"decision":"partial","amount":68}}"#,
  ])
  let operon = Operon(
    model: provider,
    grounding: RecordingGrounding(),
    policy: OperonPolicy(planning: .never)
  )

  let result: OperonResult<Decision> = try await operon.run(
    "Determine the allowed amount.",
    outputSchema: decisionSchema,
    validateOutput: { decision in
      decision.amount == 68
        ? []
        : ["amount must equal the already alcohol-free food subtotal of 68"]
    }
  )

  #expect(result.output.amount == 68)
  #expect(result.wasRepaired)
  #expect(await provider.requestCount == 2)
}

#if os(macOS)
  @Test
  func rustCoreFFIDrivesACommandEventSession() throws {
    #expect(OperonCoreSession.abiVersion == "0.3")

    let session = try OperonCoreSession(
      query: "What is two plus two?",
      configJSON: #"{"policy":{"planning":"never"}}"#
    )

    let initial = try session.start()
    guard case .command(let commandJSON) = initial else {
      Issue.record("The first core step must be a command.")
      return
    }
    #expect(commandJSON.contains("\"generate\""))

    let snapshotJSON = try session.snapshotJSON()
    #expect(snapshotJSON.contains("\"snapshot_version\":2"))
    session.close()
    let restored = try OperonCoreSession(snapshotJSON: snapshotJSON)

    let event =
      #"{"kind":"generation_completed","protocol_version":"0.3","request_id":1,"response":{"text":"{\"answer\":\"Four.\",\"confidence\":0.95,\"used_source_ids\":[]}","prompt_tokens":null,"completion_tokens":null,"finish_reason":null}}"#
    let completed = try restored.resume(eventJSON: event)
    guard case .complete(let resultJSON) = completed else {
      Issue.record("The completed generation must terminate the core session.")
      return
    }
    #expect(resultJSON.contains("Four."))
  }

  @Test
  func rustCoreCancellationReturnsATerminalOutcome() throws {
    let session = try OperonCoreSession(
      query: "Explain this",
      configJSON: #"{"policy":{"planning":"never"}}"#)
    _ = try session.start()

    let cancelled = try session.cancel(reason: "application backgrounded")

    guard case .complete(let resultJSON) = cancelled else {
      Issue.record("Cancellation must complete the session.")
      return
    }
    #expect(resultJSON.contains("\"status\":\"cancelled\""))
    #expect(resultJSON.contains("application backgrounded"))
  }
#endif

@Test
func sqliteGroundingIndexesIncrementallyAndSearchesLocally() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("operon-sqlite-grounding-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory) }
  let provider = try SQLiteOperonGroundingProvider(
    url: directory.appendingPathComponent("grounding.sqlite"))
  let documents = [
    OperonDocument(id: "refunds", path: "refunds.md", text: "Refunds are allowed for 30 days."),
    OperonDocument(id: "shipping", path: "shipping.md", text: "Express shipping takes one day."),
  ]

  #expect(try await provider.index(documents) == 2)
  #expect(try await provider.index(documents) == 0)
  let sources = try await provider.search("refund window", limit: 3)
  #expect(sources.first?.id == "refunds")
}

@Test
func sqliteMemoryFiltersScopeBeforeFTSRanking() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("operon-sqlite-memory-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory) }
  let memory = try SQLiteOperonMemoryStore(
    url: directory.appendingPathComponent("memory.sqlite"))
  let allowed = OperonMemoryRecord(
    namespace: "customer-42",
    kind: .preference,
    content: "Customer prefers concise weather summaries.",
    authority: .userConfirmed)
  let isolated = OperonMemoryRecord(
    namespace: "customer-99",
    kind: .preference,
    content: "Customer prefers concise weather summaries.",
    authority: .userConfirmed)
  _ = try await memory.put(allowed)
  _ = try await memory.put(isolated)

  let results = try await memory.search(
    "concise weather",
    scope: OperonMemoryScope(namespace: "customer-42"),
    limit: 5)

  #expect(results.map(\.id) == [allowed.id])
  #expect(try await memory.tombstone(allowed.id))
  let exported = try await memory.export(scope: OperonMemoryScope(namespace: "customer-42"))
  #expect(exported.first?.status == .tombstoned)
  #expect(
    try await memory.search(
      "concise weather", scope: OperonMemoryScope(namespace: "customer-42"), limit: 5
    ).isEmpty)
}

#if os(macOS)
  @Test
  func rustCoreDriverExecutesGroundingAndGenerationLocally() async throws {
    let provider = ScriptedProvider([
      #"{"answer":"The allowed amount is $68 [S1]","confidence":0.9,"used_source_ids":["S1"]}"#
    ])
    let driver = OperonCoreDriver(
      model: provider,
      grounding: RecordingGrounding(),
      policy: OperonPolicy(planning: .never)
    )

    let result = try await driver.run("Determine the allowed amount.")
    #expect(result.json.contains("The allowed amount is $68"))
    #expect(await provider.requestCount == 1)
  }
#endif

#if os(macOS)
  @Test
  func rustCoreDriverRepairsTypedOutputAfterApplicationValidation() async throws {
    let provider = ScriptedProvider([
      #"{"answer":"The amount is $48.","confidence":0.9,"used_source_ids":[],"output":{"decision":"partial","amount":48}}"#,
      #"{"answer":"The amount is $68.","confidence":0.9,"used_source_ids":[],"output":{"decision":"partial","amount":68}}"#,
    ])
    let driver = OperonCoreDriver(
      model: provider,
      policy: OperonPolicy(planning: .never, maximumRepairAttempts: 1)
    )

    let outcome: OperonRunOutcome<Decision> = try await driver.run(
      "Determine the allowed amount.",
      outputSchema: decisionSchema,
      validateOutput: { decision in
        decision.amount == 68 ? [] : ["amount must equal 68"]
      }
    )

    guard case .completed(let result) = outcome else {
      Issue.record("The repaired answer should complete.")
      return
    }

    #expect(result.output == Decision(decision: "partial", amount: 68))
    #expect(result.wasRepaired)
    #expect(await provider.requestCount == 2)
  }
#endif

#if os(macOS)
  @Test
  func rustCoreDriverExecutesRegisteredSkillsAndReturnsReceipts() async throws {
    let provider = ScriptedProvider([
      #"{"intent":"Create lunch","subquestions":[],"needs_grounding":false,"answer_requirements":[],"skill_calls":[{"skill_id":"calendar.create","arguments":{"title":"Lunch"}}]}"#,
      #"{"answer":"Created lunch.","confidence":0.95,"used_source_ids":[]}"#,
    ])
    let skills = RecordingSkillHost()
    let driver = OperonCoreDriver(
      model: provider,
      policy: OperonPolicy(planning: .always),
      skillHost: skills,
      completion: OperonCompletionContract(requiredSkillIDs: ["calendar.create"])
    )

    let result = try await driver.run("Create a lunch event")

    #expect(result.json.contains("\"skill_id\":\"calendar.create\""))
    #expect(await skills.invocations == 1)
  }

  @Test
  func rustCoreDriverStreamsOnlyProvisionalModelOutputBeforeCompletion() async throws {
    let provider = ScriptedProvider([
      #"{"answer":"Four.","confidence":0.95,"used_source_ids":[]}"#
    ])
    let driver = OperonCoreDriver(
      model: provider,
      policy: OperonPolicy(planning: .never)
    )
    var sawProvisional = false
    var sawMeasurement = false
    var finalStatus: OperonCoreRunStatus?
    var terminalJSON: String?

    for try await event in driver.stream("What is two plus two?") {
      if case .provisionalModelOutput = event { sawProvisional = true }
      if case .measurement = event { sawMeasurement = true }
      if case .finished(let status, let json) = event {
        finalStatus = status
        terminalJSON = json
      }
    }

    #expect(sawProvisional)
    #expect(sawMeasurement)
    #expect(finalStatus == .completed)
    // A streamed turn must DELIVER its answer, not merely report that one
    // exists. Yielding a bare status forced a caller to run the whole turn
    // again to find out what it concluded, and grounded turns take seconds.
    let json = try #require(terminalJSON)
    #expect(json.contains("\"status\":\"completed\""))
    #expect(json.contains("four") || json.contains("4"))
  }
#endif

#if os(macOS)
  @Test
  func durableMemoryIsScopedPersistentAndInjectedThroughTheCore() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operon-memory-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let memory = try FileOperonMemoryStore(url: url)
    let scope = OperonMemoryScope(namespace: "customer-42")
    _ = try await memory.put(
      OperonMemoryRecord(
        namespace: scope.namespace,
        kind: .preference,
        content: "Customer prefers concise answers.",
        authority: .userConfirmed
      )
    )
    _ = try await memory.put(
      OperonMemoryRecord(
        namespace: "customer-99",
        kind: .preference,
        content: "This other customer's memory must never be returned.",
        authority: .userConfirmed
      )
    )

    let provider = ScriptedProvider([
      #"{"answer":"Noted.","confidence":0.9,"used_source_ids":[]}"#
    ])
    let driver = OperonCoreDriver(
      model: provider,
      memory: memory,
      memoryScope: scope,
      policy: OperonPolicy(planning: .never)
    )
    _ = try await driver.run("How should I respond?")

    let prompt = await provider.lastPrompt
    #expect(prompt.contains("Customer prefers concise answers."))
    #expect(!prompt.contains("other customer's memory"))
    let stored = try FileOperonMemoryStore(url: url)
    let records = try await stored.search("concise", scope: scope, limit: 5)
    #expect(records.count == 1)
    let tombstoned = try await stored.tombstone(records[0].id)
    #expect(tombstoned)
    let afterTombstone = try await stored.search("concise", scope: scope, limit: 5)
    #expect(afterTombstone.isEmpty)
  }
#endif

// MARK: - generation schema naming

/// Collects every object name in a schema tree so duplicates are detectable.
private func objectNames(_ schema: OperonSchema, into names: inout [String]) {
  switch schema {
  case .object(let name, _, let properties):
    names.append(name)
    for property in properties { objectNames(property.schema, into: &names) }
  case .array(let items, _, _):
    objectNames(items, into: &names)
  case .definitions(let root, let values):
    objectNames(root, into: &names)
    for key in values.keys.sorted() { objectNames(values[key]!, into: &names) }
  case .string, .number, .integer, .boolean, .reference:
    break
  }
}

/// A schema with `$defs` arrives at the driver with its references already
/// inlined, so nested objects are structurally distinct types that must not
/// share an identifier. `DynamicGenerationSchema` keys generated types by
/// name, and duplicate names made Apple's provider fail to deserialize model
/// output for the extractive answer schema — root, `claim` and `evidence`
/// were all called `OperonCoreResponse`.
///
/// Citation mode has a single object and never collided, which is why this
/// went unnoticed: the mode with nested objects had no provider coverage.
@Test("inlined $defs produce uniquely named objects")
func generationSchemaNamesNestedObjectsUniquely() throws {
  // The shape of `answer_schema` in extractive mode.
  let raw: [String: Any] = [
    "$defs": [
      "evidence": [
        "type": "object",
        "properties": [
          "source_id": ["type": "string"],
          "quote": ["type": "string"],
        ],
        "required": ["source_id", "quote"],
      ],
      "claim": [
        "type": "object",
        "properties": [
          "text": ["type": "string"],
          "evidence": [
            "type": "array",
            "items": ["$ref": "#/$defs/evidence"],
            "minItems": 1,
          ],
        ],
        "required": ["text", "evidence"],
      ],
    ],
    "type": "object",
    "properties": [
      "claims": ["type": "array", "items": ["$ref": "#/$defs/claim"]],
      "confidence": ["type": "number", "minimum": 0, "maximum": 1],
      "abstain_reason": ["type": "string"],
    ],
    "required": ["claims", "confidence", "abstain_reason"],
  ]

  let schema = try JSONSchema(object: raw).operonSchema()
  var names: [String] = []
  objectNames(schema, into: &names)

  #expect(names.count == 3, "root, claim and evidence are three distinct objects")
  #expect(Set(names).count == names.count, "object names must be unique: \(names)")
}
