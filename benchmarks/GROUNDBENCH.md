# GroundBench

GroundBench measures whether a local model answers supported questions,
declines unsupported ones, and provides evidence that can be checked without a
second model call. It is deliberately separate from AppBench, which measures
whether Operon completes app-owned actions.

## Corpus

Version 0.1 contains eight synthetic local-knowledge cases:

- four answerable policy or safety questions; and
- four deliberately unsupported requests for a duration, override code,
  mileage rate, or encryption algorithm absent from the supplied documents.

Every case declares transparent acceptable phrases and forbidden claims. Both
the raw and Operon extractive configurations receive the same whitespace-
canonicalized evidence. The suite and fixtures are in `ground_cases.json` and
`fixtures/`.

## Configurations

| Configuration | What the model receives | What the runtime checks |
| --- | --- | --- |
| `raw_full_context` | Every case document and the extractive response schema | Nothing before returning the model output |
| `operon_citation` | Operon-retrieved chunks and the citation response schema | Source IDs and inline citation consistency |
| `operon_extractive` | Operon-retrieved canonical chunks and the claim/evidence schema | Every quote is long enough and an exact substring; byte offsets and citations are derived |

All configurations use the same model, temperature family, documents, and
deterministic evaluator. Operon uses `planning="never"` so this benchmark
isolates grounding and validation rather than planning quality.

## Metrics

- **Complete supported answers:** all required fact groups are present and no
  forbidden conclusion appears.
- **Safe refusal:** an unsupported case returns a structured abstention or an
  explicit evidence-insufficient answer without a forbidden claim.
- **Unsupported answer:** an unsupported case completes without a safe refusal.
- **Every quote exact:** among quote-bearing records, every evidence quote is
  an exact substring of the supplied evidence chunk and meets the minimum
  length.
- **Citation integrity:** declared source IDs exist and equal the inline
  citation markers.
- **Latency and calls:** median/p95 wall time and average model calls.

The exact-quote check verifies attribution, not semantic entailment. A quote
may exist while a model's paraphrase overstates it. That is why safe refusal and
unsupported-answer rate remain separate primary metrics.

## v0.3 development result

Qwen3 4B Q4_K_M ran eight cases three times through local Ollama on an Apple
Silicon desktop on July 25, 2026: 24 records per configuration.

| Configuration | Complete supported answers | Safe refusal | Unsupported answers | Every quote exact | Median | Calls |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Raw full context | 75.0% | 0.0% | 100.0% | 75.0% | 1,265 ms | 1.00 |
| Operon citation | 25.0% | 50.0% | 50.0% | n/a | 640 ms | 1.17 |
| **Operon extractive** | **75.0%** | **41.7%** | **58.3%** | **100.0%** | **1,197 ms** | **1.12** |

The result supports one narrow release claim: no invalid quote escaped strict
Operon in this run, and the runtime enforces that property deterministically.
It also exposes a clear gap: Qwen3 4B still used valid but irrelevant evidence
instead of refusing some unsupported requests. v0.3 must not be described as a
semantic-entailment verifier.

The machine-readable summary, corpus digest, environment, and caveats are in
[`published/groundbench-qwen3-4b-v0.3-3x.summary.json`](published/groundbench-qwen3-4b-v0.3-3x.summary.json).
These are desktop measurements, not iPhone latency, memory, energy, or thermal
results.

## Run it

With Ollama already serving a model:

```bash
PYTHONPATH=sdk/python/src:. python3 -m benchmarks.groundbench \
  --model qwen3:4b \
  --repetitions 3
```

Use `--case` or `--config` repeatedly for focused runs. Detailed JSONL and a
summary are written under `benchmarks/results/`, which is intentionally ignored
until a result has been reviewed for publication.

## Publication rules

- Publish the suite digest, model, quantization, repetitions, host class, and
  evaluator version.
- Keep raw and Operon evidence representations identical.
- Report safe refusal beside quote validity.
- Do not describe desktop results as on-device mobile performance.
- Do not turn a finite observed rate into a universal model guarantee. The
  exact-substring validator is a deterministic guarantee; benchmark rates are not.
