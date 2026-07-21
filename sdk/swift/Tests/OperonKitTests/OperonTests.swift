import Foundation
import Testing

@testable import OperonCoreDriver
@testable import OperonCoreFFI
@testable import OperonKit

private struct Decision: Codable, Sendable, Equatable {
  let decision: String
  let amount: Double
}

private actor ScriptedProvider: OperonModelProvider {
  private var responses: [String]
  private(set) var requestCount = 0

  init(_ responses: [String]) {
    self.responses = responses
  }

  func availability() async -> OperonAvailability {
    .available
  }

  func generate(_ request: OperonGenerationRequest) async throws -> OperonGenerationResponse {
    requestCount += 1
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
    #expect(OperonCoreSession.abiVersion == "0.1")

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

    let event =
      #"{"kind":"generation_completed","protocol_version":"0.1","request_id":1,"response":{"text":"{\"answer\":\"Four.\",\"confidence\":0.95,\"used_source_ids\":[]}","prompt_tokens":null,"completion_tokens":null,"finish_reason":null}}"#
    let completed = try session.resume(eventJSON: event)
    guard case .complete(let resultJSON) = completed else {
      Issue.record("The completed generation must terminate the core session.")
      return
    }
    #expect(resultJSON.contains("Four."))
  }
#endif

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
