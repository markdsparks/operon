# AppBench: does the app actually get smarter?

AppBench measures the product question behind Operon:

> Can the same small local model complete real work inside an app more reliably
> when it runs inside Operon?

It is deliberately separate from the document-grounding benchmark. Citation
quality matters, but app developers also need to know whether a model can carry
context across turns, resolve references, prepare exact capability arguments,
ask for missing input, follow a dependent action chain, and stop safely.

## The workload

The versioned corpus contains 20 synthetic, domain-diverse app scenarios, with
four cases in each category:

| Category | What it tests | Example |
| --- | --- | --- |
| Reference resolution | Carries typed focus across turns | “Book the second one tomorrow morning.” |
| Argument preparation | Converts semantic references into canonical app values | Resolve “that photo” and “Maya” into app-owned IDs |
| Multi-step jobs | Uses one result to choose and complete the next action | Find a file, then share the returned file |
| Clarification | Does not invent required missing input | Ask which workspace and time to book |
| Safe failure | Stops before an unavailable or forbidden side effect | Reject an over-limit payment |

Every scenario declares the authorized skill catalog, typed app state, host
preparation behavior, deterministic skill results, and the exact expected
invocation sequence. The suite and evaluator are content-addressed so results
cannot silently move to a different corpus.

## The comparison

The v0.2 runner compares three configurations using the same model:

- `direct_raw`: a strong raw tool loop. The model receives the recent
  transcript, full app-state values, completed skill results, skill
  descriptions, and schemas. It must resolve canonical arguments itself.
- `operon_linear`: the v0.1 harness. The model sees bounded artifact references;
  Operon prepares arguments, validates calls, suppresses repeats, and performs
  bounded global replanning.
- `operon`: the v0.2 TaskGraph harness. In addition to the linear controls,
  skills declare typed artifact dependencies, the app declares a completion
  contract, and structured decoding is limited to the current ready set.

In both Operon configurations, the model sees bounded artifact references.
Operon routes the request, lets host code prepare and validate canonical
arguments, suppresses repeated skills, requires a skill or clarification, and
replans within a fixed limit.

This is intentionally conservative toward Operon: the raw baseline sees the
full artifact values, while the Operon planner sees only model-safe summaries
and IDs. Host policy blocks forbidden side effects in both configurations; the
benchmark never treats a dangerous invocation as acceptable.

Each turn gets at most three model-directed steps. A run succeeds only when the
whole requested job reaches a safe terminal state. Selecting the right skill
once and then repeating it is a failure, not partial credit, because duplicate
side effects are dangerous in real apps.

## Primary metrics

- **Task completion:** exact end-to-end capability sequence, correct
  clarification, or safe terminal refusal.
- **Skill routing:** correct ordered capability choice.
- **Exact arguments:** every invoked skill received the declared canonical
  arguments.
- **Clarification accuracy:** missing inputs produced a question and no side
  effect.
- **Safe failure:** forbidden or unavailable work reached no handler.
- **Latency and model calls:** the cost of reliability, not just its quality.

## Run it

With Ollama and `qwen3:4b` available locally:

```bash
PYTHONPATH=sdk/python/src:. python3 -m benchmarks.appbench \
  --model qwen3:4b \
  --repetitions 3
```

Filter by category or case while developing:

```bash
PYTHONPATH=sdk/python/src:. python3 -m benchmarks.appbench \
  --model qwen3:4b \
  --category dependent_chain \
  --repetitions 1
```

The focused v0.2 release check can be reproduced with:

```bash
PYTHONPATH=sdk/python/src:. python3 -m benchmarks.appbench \
  --model qwen3:4b \
  --category dependent_chain \
  --repetitions 3
```

Saved interactions can be deterministically rescored after evaluator fixes:

```bash
PYTHONPATH=sdk/python/src:. python3 -m benchmarks.app_rescore \
  benchmarks/results/appbench-qwen3-4b-v0.1-3x.jsonl
```

The runner also accepts any explicitly authorized OpenAI-compatible endpoint,
so the same workload can be run against larger local models or a cloud
reference. Remote execution requires `--allow-remote`; credentials stay in the
environment.

## What v0.2 does not prove

This is a development benchmark, not a general intelligence ranking. The
scenarios are synthetic, the first documented run covers one quantized 4B
model on one machine, and exact deterministic scoring can reject a semantically
equivalent argument. It does not yet measure cold start, memory use, battery
impact, cancellation, or long-session memory isolation.

The next publication-grade expansion should add more phrasings and domains,
human adjudication, 1.5B–8B local model tiers, a cloud reference, device energy
measurements, and explicit memory-lifecycle and adversarial-permission tracks.
