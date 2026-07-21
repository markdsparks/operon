import Foundation
import OperonCoreDriver
import OperonFoundationModels
import OperonKit

private struct ExpenseDecision: Codable, Sendable {
  let decision: String
  let reimbursableAmountUSD: Double
  let excludedItems: [String]

  enum CodingKeys: String, CodingKey {
    case decision
    case reimbursableAmountUSD = "reimbursable_amount_usd"
    case excludedItems = "excluded_items"
  }
}

private struct Expense: Sendable {
  let foodSubtotal: Double
  let alcoholSubtotal: Double
}

private struct ExpenseDecisionGrounding: OperonGroundingProvider {
  let expense: Expense

  func search(_ query: String, limit: Int) async throws -> [OperonSource] {
    let reimbursableAmount = min(expense.foodSubtotal, 75)
    return [
      OperonSource(
        id: "S1",
        path: "expense-policy.md",
        text: """
          Individual business meals reimburse food, tax, and tip up to $75 per day.
          Alcohol is never reimbursable and must be excluded from the submitted amount.
          """
      ),
      OperonSource(
        id: "S2",
        path: "expense-calculation.json",
        text: """
          Deterministic application calculation:
          food_subtotal_usd=\(expense.foodSubtotal)
          alcohol_subtotal_usd=\(expense.alcoholSubtotal)
          reimbursable_amount_usd=\(reimbursableAmount)
          decision=partial
          excluded_items=alcoholic drink
          The alcohol subtotal is separate and has not been included in or subtracted from the food subtotal.
          """,
        score: 2
      ),
    ]
  }
}

@main
private enum OperonExpenseDemo {
  static func main() async {
    let provider = AppleFoundationModelsProvider()
    let expense = Expense(foodSubtotal: 68, alcoholSubtotal: 20)
    let operon = OperonCoreDriver(
      model: provider,
      grounding: ExpenseDecisionGrounding(expense: expense),
      policy: OperonPolicy(planning: .always, maximumRepairAttempts: 2)
    )
    let schema = OperonSchema.object(
      name: "ExpenseDecision",
      description: "A policy-grounded expense decision.",
      properties: [
        .init(
          "decision",
          description:
            "Use full if every item is reimbursable, partial if some items are excluded, and deny if nothing is reimbursable.",
          schema: .string(choices: ["full", "partial", "deny"])
        ),
        .init(
          "reimbursable_amount_usd",
          description: "The exact permitted amount after exclusions.",
          schema: .number(minimum: 0)
        ),
        .init(
          "excluded_items",
          description: "Every claimed item excluded by policy.",
          schema: .array(items: .string())
        ),
      ]
    )

    do {
      let result: OperonResult<ExpenseDecision> = try await operon.run(
        "An individual dinner has $68 of food and a separate $20 alcoholic drink. The receipt is itemized. Determine exactly how much is reimbursable.",
        outputSchema: schema,
        validateOutput: { decision in
          var errors: [String] = []
          if decision.reimbursableAmountUSD != expense.foodSubtotal {
            errors.append(
              "reimbursable_amount_usd must equal the $68 food subtotal; the separate $20 alcohol charge is excluded, not subtracted from food"
            )
          }
          if expense.alcoholSubtotal > 0 && decision.decision != "partial" {
            errors.append("decision must be partial because one claimed item is excluded")
          }
          if expense.alcoholSubtotal > 0 && decision.excludedItems.isEmpty {
            errors.append("excluded_items must identify the alcoholic drink")
          }
          return errors
        }
      )
      print(result.answer)
      print("decision=\(result.output.decision)")
      print("reimbursable_amount_usd=\(result.output.reimbursableAmountUSD)")
      print("excluded_items=\(result.output.excludedItems.joined(separator: ", "))")
      print("sources=\(result.sources.map(\.path).joined(separator: ", "))")
    } catch {
      print("OperonExpenseDemo: \(error.localizedDescription)")
    }
  }
}
