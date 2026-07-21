# Operon benchmark harness

The harness compares four ways of using the same model:

1. `question_only`: direct structured call with no local documents.
2. `all_context`: direct call with every case document inserted manually.
3. `operon_unverified`: Operon planning and retrieval without semantic
   provenance validation or repair.
4. `operon_full`: the complete planning, retrieval, validation, and repair loop.

This separation measures whether gains come from merely having context,
retrieving the right context, or enforcing the complete runtime contract.

## Run

With Ollama running locally:

```bash
PYTHONPATH=sdk/python/src:. python3 -m benchmarks.run \
  --model qwen3:4b \
  --repetitions 3
```

Run a smaller smoke matrix:

```bash
PYTHONPATH=sdk/python/src:. python3 -m benchmarks.run \
  --model qwen3:4b \
  --case refund_final_sale \
  --config question_only \
  --config operon_full
```

Each run writes detailed JSONL records and a summary JSON file under
`benchmarks/results/`. Generated results are ignored by version control because
model and runtime metadata should be reviewed before publishing them.

Every record includes a run UUID, protocol and evaluator versions, Operon
version, Python/platform metadata, and a SHA-256 digest over the case definition
and source documents. Results can therefore detect corpus drift instead of
silently comparing different tests.

When deterministic scoring rules improve, re-evaluate saved model outputs
without spending another inference run:

```bash
PYTHONPATH=sdk/python/src:. python3 -m benchmarks.rescore \
  benchmarks/results/qwen3-4b-initial.jsonl
```

## Current scoring

Cases declare human-authored groups of acceptable phrases, forbidden claims,
expected source filenames, and optional exact terse answers. The first phrase group scores the core decision;
all groups together score answer completeness. Source precision, source recall,
and citation consistency are scored separately.

Phrase scoring is intentionally transparent and deterministic, but it is only a
first evaluator. It can miss correct paraphrases or accidentally accept an
answer that repeats a phrase in the wrong context. Published claims require
human review and, later, task-specific structured evaluators.

## Adding a case

Add documents under `benchmarks/fixtures/<case_id>/` and an entry to
`benchmarks/cases.json` containing:

- a self-contained query;
- relevant and distracting documents;
- groups of acceptable answer phrases;
- phrases that would make the decision incorrect; and
- the filenames expected as evidence.

Keep the correct decision derivable exclusively from the supplied documents.

## Model matrix

Run the same corpus and repetitions across multiple local models:

```bash
PYTHONPATH=sdk/python/src:. python3 -m benchmarks.matrix \
  --model qwen2.5-coder:1.5b \
  --model qwen3:4b \
  --model llama3.1:8b \
  --repetitions 3
```

The coordinator preserves each model's JSONL output and writes a combined
`matrix-summary.json`. Use `--case` and `--config` repeatedly for a staged smoke
run before committing to the full matrix.

## Fair local and cloud comparison

Use a profile manifest to compare local and cloud models against the same cases,
authorized documents, output contracts, and scoring rules. Start from
`benchmarks/profiles.example.json`; credentials are named by environment
variable and never stored in the manifest or result files. A remote profile must
also explicitly set `"allow_remote": true`; this is limited to the benchmark
process and does not change Operon's privacy-first product default.
If a cloud model rejects `max_tokens`, set its profile's
`"completion_token_parameter": "max_completion_tokens"`; local profiles
continue to use the default `max_tokens`.

```bash
export OPERON_CLOUD_API_KEY=...
PYTHONPATH=sdk/python/src:. python3 -m benchmarks.compare \
  --profiles benchmarks/profiles.json \
  --repetitions 5
```

The comparison writes one raw JSONL file per profile plus `comparison.json`.
It reports decision reliability, completeness, provenance, mean/median/p95
latency, model calls, token use, repair rate, and optional price-table cost
estimates. Local costs remain zero unless you explicitly choose a device-cost
model; latency and tokens are reported separately.

Interpret comparisons in two dimensions: direct local versus local Operon
measures runtime uplift, while local Operon versus a cloud direct profile is a
quality/latency/cost reference. Do not treat either as a general intelligence
ranking. Run at least five repetitions and review disagreements before making a
public claim.
