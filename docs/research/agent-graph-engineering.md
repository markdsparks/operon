# Agent graph engineering: implications for Operon

Research pass: July 23, 2026.

## What converged

Current agent runtimes are converging on explicit graph state around model
calls, but for different reasons:

- [LangGraph persistence](https://docs.langchain.com/oss/python/langgraph/persistence)
  treats checkpoints as the basis for fault tolerance, interrupts, inspection,
  and resuming without re-running already successful nodes.
- [AutoGen GraphFlow](https://microsoft.github.io/autogen/dev/user-guide/agentchat-user-guide/graph-flow.html)
  recommends graphs when a workflow needs strict action order, conditional
  branches, or bounded loops rather than ad-hoc conversational routing.
- [Google ADK 2.0](https://adk.dev/2.0/) moves agents, tools, and functions onto a
  graph runtime to improve control, predictability, and reliability; its
  [Go 2.0 announcement](https://developers.googleblog.com/announcing-adk-go-20/)
  also emphasizes persisted state, pause/resume, retries, and a shared runtime.
- [AFlow](https://arxiv.org/abs/2410.10762) frames workflow quality as a search
  problem over graph connectivity and node behavior, reinforcing that
  orchestration structure—not only model choice—affects measured performance.
- [AgentFlow](https://arxiv.org/abs/2607.01640) models capabilities, memory,
  prompts, and control policies as typed nodes and dependencies, showing the
  governance and security value of an analyzable graph representation.

## What Operon adopts

Operon v0.2 adopts the smallest subset that directly improves an embedded local
SLM harness:

1. Typed capability data edges through `consumes` and `produces` artifact kinds.
2. A deterministic completion contract owned by the application.
3. A goal-relevant ready set instead of a flat catalog on every model turn.
4. Structured-decoding constraints that prevent out-of-set capability IDs.
5. Command-boundary snapshots, stable idempotency keys, and completed receipts.
6. Bounded replanning only where semantic argument interpretation is still
   useful.

This preserves the simple `Operon.wrap(model)` entry point. The graph is an
internal reliability representation, not a required visual builder.

## What Operon does not adopt yet

- Multi-agent teams: they add cost and coordination state without addressing
  the current small-model failure first.
- Arbitrary loops or autonomous graph expansion: local/mobile budgets require
  explicit limits and completion checks.
- Parallel fan-out: useful later for independent retrieval or sensor work, but
  it needs energy, cancellation, merge, and error policy first.
- A graph database: the execution graph is small typed runtime state, while
  durable semantic memory remains a separate host-owned concern.
- Automatic workflow optimization: AppBench should accumulate broader models
  and cases before search-based graph mutation is justified.

## Next evidence to collect

- Repeat the full AppBench matrix across 1.5B, 4B, and 8B local tiers.
- Measure cold start, memory, latency, and energy on real iOS hardware.
- Add failure-injection cases for snapshot restore and idempotent redelivery.
- Add bounded branch, retry, compensation, and human-confirmation tracks before
  implementing those graph primitives.
