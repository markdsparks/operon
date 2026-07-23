# ADR 0003: Goal-directed TaskGraph and constrained ready set

- Status: accepted
- Date: 2026-07-23

## Context

Operon's linear bounded replanning improved app-task completion, but AppBench
showed a repeatable failure on dependent work: a 4B model completed a lookup and
then selected that lookup again instead of the requested follow-on action.
Duplicate suppression prevented a repeated side effect but could not prove that
the user's whole job was complete.

Recent agent-runtime work broadly favors explicit execution state, typed
dependencies, checkpointing, and deterministic control around model-selected
actions. Operon needs those benefits without turning its drop-in API into a
visual workflow builder or adopting a multi-agent abstraction.

## Decision

Operon compiles an internal goal-directed TaskGraph from application contracts:

- each skill may declare typed artifact kinds it `consumes` and `produces`;
- a session may declare required skill IDs and artifact kinds through a
  `CompletionContract`;
- the runtime walks backward from that goal to retain only relevant skills;
- a skill enters the ready set only when all consumed artifact kinds exist;
- planning and replanning schemas constrain `skill_id` to the ready set;
- successful skills validate their promised artifacts and publish a receipt;
- normal completion is impossible while the contract remains unmet; and
- command-boundary snapshots plus idempotency keys support safe recovery.

The model still interprets the request and proposes semantic arguments. The
host still owns preparation, canonical private values, permissions, business
rules, and side effects. The graph owns dependency order and completion truth.

## Consequences

- Small models search a much smaller next-action space.
- A plausible answer cannot silently replace unfinished app work.
- Existing flat skill catalogs remain compatible when dependency and completion
  fields are omitted.
- Apps must choose meaningful artifact kinds and completion requirements for
  workflows that need graph guarantees.
- The graph does not add parallel execution, compensation, or arbitrary loops;
  those require separate bounded policies and evidence.
- A visual graph editor and multi-agent framework remain non-goals for v0.2.
