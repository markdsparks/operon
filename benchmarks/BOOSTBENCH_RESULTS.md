# BoostBench development results

## First Instant Boost run: a one-call local reliability gain

The first complete BoostBench run compares a direct full-context prompt with
Operon's `operon_instant` configuration. Both use the same local `qwen3:4b`
Q4_K_M model through Ollama, the same 30 human-reviewed grounded-decision
cases, and three repetitions per case (90 runs per configuration).

| Metric | Direct full context | Qwen3 4B + Instant Boost | Difference |
| --- | ---: | ---: | ---: |
| Decision accuracy | 73.3% | **82.2%** | **+8.9 points** |
| Complete answers | 20.0% | **53.3%** | **+33.3 points** |
| Valid provenance | 3.3% | **100.0%** | **+96.7 points** |
| Source recall | **100.0%** | **100.0%** | — |
| Median latency | **501 ms** | 727 ms | +226 ms |
| P95 latency | **873 ms** | 1,118 ms | +245 ms |
| Average model calls | 1.00 | **1.00** | — |

This is the result the first-wrapper design needed to establish: Operon did
not add a planner call to earn the improvement. The fast path retrieved local
context, generated once, and checked the result locally. Its 88.9% repair rate
was deterministic citation normalization, not another inference call.

The direct arm received every authorized document in the prompt. Instant Boost
used bounded retrieval, a structured response contract, provenance validation,
and repair only when the deterministic validator could safely perform it.

## Reproduction record

- Run date: August 17, 2026
- Commit: `1799fdd2949611ef6a59c706138af4794e234669`
- Model: `qwen3:4b`, Q4_K_M, through Ollama 0.32.14
- Host: Apple arm64, macOS 26.6.1; Python 3.14.6
- Benchmark protocol/evaluator: 1.0 / 1.2
- Cases: 30; repetitions: 3; runs per configuration: 90
- Suite digest: `9540a2516427e5c2e78cdf6f82bf3b6a6ebdc18071ad02a7166e82d1361cc243`
  (SHA-256 of the sorted per-case corpus digests)

The matching [machine-readable summary](published/boostbench-qwen3-4b-instant-3x.summary.json)
contains the exact figures and run metadata.

## What it proves—and what it does not

It is a focused development result for one local 4B model and one reviewed
corpus. It does not establish performance on iPhone hardware, energy use,
thermal behavior, or a general ranking across models. A second provider/model
tier and physical-device measurements remain required before making broader
claims.
