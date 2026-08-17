# BoostBench

BoostBench measures Operon's first promise: keep the same model and add a
small, bounded reliability layer before adopting skills, memory, or a task
graph.

The initial track reuses the reviewed 30-case grounded-decision corpus and adds
`operon_instant`, a configuration with local retrieval, structured generation,
validation, and bounded repair—but no planning call. Compare it with
`all_context`, where the same model receives every authorized case document in
one direct prompt.

```bash
PYTHONPATH=sdk/python/src:. python3 -m benchmarks.run \
  --model qwen3:4b \
  --config all_context \
  --config operon_instant \
  --repetitions 3
```

## What this isolates

- Both arms use the same model, provider, case query, documents, and output
  schema.
- The direct arm receives all documents; Operon retrieves a bounded subset.
- `operon_instant` skips the model planner, so a valid answer takes one model
  call. A second call occurs only when deterministic validation requests a
  targeted repair.
- The evaluator reports decision quality, completeness, provenance, source
  recall/precision, latency, model calls, tokens, and repair rate.

This track does not measure app actions, multi-turn reference resolution, or
memory. AppBench owns those advanced harness capabilities. GroundBench owns
strict evidence and safe-refusal measurement.

## Publication gate

Before publishing an Instant Boost claim:

1. run at least three repetitions on the complete human-reviewed corpus;
2. report the suite digest, model, quantization, host, and evaluator version;
3. publish accuracy beside p50/p95 latency, model calls, and repair rate;
4. repeat on at least two model/provider tiers; and
5. publish physical-device memory, energy, and thermal measurements for mobile
   claims.

The next track will add provider-neutral typed extraction cases with no local
documents. That will isolate schema validity and repair for a literal
`Operon.wrap(model)` call.

## First development result

The first complete three-repetition run is now recorded in
[BoostBench development results](BOOSTBENCH_RESULTS.md), with a tracked
[machine-readable summary](published/boostbench-qwen3-4b-instant-3x.summary.json).
