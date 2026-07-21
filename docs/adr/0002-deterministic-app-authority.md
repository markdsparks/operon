# ADR 0002: Deterministic application authority

- Status: accepted
- Date: 2026-07-21

## Context

Small language models can reliably organize context and produce constrained
output without reliably performing exact arithmetic or enforcing every business
invariant. A generated value can satisfy its JSON schema while still being
wrong. Repeated prompting does not turn probabilistic generation into a trusted
calculator, permission system, or side-effect controller.

## Decision

Applications retain authority over deterministic calculations, permissions,
side effects, and hard domain invariants. They expose computed facts to Operon
as tool results or authoritative grounding and may register output validators.
The model interprets, classifies, synthesizes, and explains those facts. Operon
rejects output that fails app validation and may request a bounded repair.

## Consequences

- Exact operations remain testable code rather than prompt conventions.
- Typed schemas define shape but do not replace semantic validation.
- Models can add useful language and judgment without becoming the source of
  truth for arithmetic or authorization.
- Apps must identify which parts of a workflow require deterministic authority.
- Validation failures are safe failures: Operon does not return a plausible but
  known-invalid result after the repair budget is exhausted.
