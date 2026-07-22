# AppBench v0.1 development results

## Qwen3 4B: 90% with Operon versus 20% raw

In the first repeated AppBench development run, the same local Qwen3 4B model
completed **90%** of app turns with Operon and **20%** in the raw full-state
tool loop—a **70 percentage-point uplift**.

The run used all 20 cases, three repetitions per case, and 60 runs per
configuration. The raw baseline received the full transcript, full app-state
values, completed results, and the same authorized skill schemas. Operon used
typed artifact references, host argument preparation, validation, required
skill-or-clarification policy, repeat suppression, and bounded replanning.

| Metric | Raw Qwen3 4B | Qwen3 4B + Operon |
| --- | ---: | ---: |
| End-to-end task completion | 20.0% | **90.0%** |
| Correct skill routing | 45.0% | **85.0%** |
| Exact canonical arguments | 0.0% | **83.3%** |
| Correct clarification | 0.0% | **100.0%** |
| Safe terminal failure | 100.0% | **100.0%** |
| Median latency | **2,194 ms** | 3,886 ms |
| Average model calls | **2.75** | 2.80 |

### Completion by capability

| AppBench category | Raw Qwen3 4B | Qwen3 4B + Operon |
| --- | ---: | ---: |
| Reference resolution | 0% | **100%** |
| Argument preparation | 0% | **100%** |
| Multi-step jobs | 0 of 12 runs | **6 of 12 runs** |
| Clarification | 0% | **100%** |
| Safe failure | **100%** | **100%** |

The raw model's 20% overall score came entirely from cases where host policy
blocked a forbidden or unavailable action. On ordinary reference, preparation,
chain, and clarification work, it frequently selected a plausible first call
but then repeated it, invented missing values, or failed to produce canonical
arguments. AppBench treats those as end-to-end failures because real apps
cannot safely accept them.

Operon's strongest result is not better prose. It is reliable conversion of
ambiguous language into app-owned state and exact arguments, plus a question
instead of an invented value when state is missing.

The important remaining gap is also clear: the 4B model finished only 6 of 12
multi-step jobs. In the misses it kept selecting the lookup capability
instead of the follow-on action. Operon prevented duplicate invocation, but it
could not make the model choose the missing next capability. Task-completeness
verification and better constrained next-action selection are now measurable
roadmap items.

Reliability also had a cost: median latency increased by about 1.7 seconds.
That tradeoff needs model-tier and on-device measurement before making broader
performance claims.

This is engineering evidence, not a publication-grade claim. See the
[AppBench methodology](APPBENCH.md), the versioned
[scenario corpus](app_cases.json), and the tracked
[machine-readable summary](published/appbench-qwen3-4b-v0.1-3x.summary.json).

Run metadata: AppBench 0.1, evaluator 0.2, Qwen3 4B Q4_K_M through Ollama,
Apple arm64 host, July 22, 2026. Suite digest:
`7c2bbc366f5eb3e404ee58c015b860eedd73d53c8c97e0bb8191834b423bd49f`.
