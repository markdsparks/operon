# Operon v0.2.0 — TaskGraph

Operon v0.2 turns a flat skill catalog into a bounded execution graph while
preserving the drop-in experience: keep the small model already in your app,
wrap it with Operon, and add typed capability dependencies only when your
workflow needs them.

## Why this release

The first AppBench run showed a precise failure: the local Qwen3 4B model could
often perform a lookup, but then repeated that lookup instead of using its
result for the requested action. Prompting and repeat suppression prevented a
duplicate side effect, but did not complete the job.

v0.2 makes the runtime—not the model—own dependency order and completion truth:

- skills declare typed artifact kinds they consume and produce;
- apps declare which skill IDs or artifact kinds are required for completion;
- Operon compiles the goal-relevant graph and computes the ready set;
- structured decoding can emit only a ready capability ID;
- host preparation resolves private canonical values and validates arguments;
- completed actions return receipts with idempotency keys; and
- execution can snapshot and restore without replaying completed work.

## Measured result

On the unchanged AppBench dependent-chain cases, repeated three times with the
same local Qwen3 4B Q4_K_M model:

| Configuration | Jobs completed | Exact routing and arguments |
| --- | ---: | ---: |
| Raw full-state loop | 0 of 12 | 0% |
| Operon linear replanning | 6 of 12 | 50% |
| **Operon v0.2 TaskGraph** | **12 of 12** | **100%** |

This is a focused development result on one model and synthetic workload, not a
general intelligence claim. The methodology and machine-readable result are in
`benchmarks/APPBENCH.md` and `benchmarks/published/`.

## Compatibility

The execution protocol remains experimental 0.2. New fields and operations are
additive. Existing skills with no dependency declarations remain flat and keep
their previous behavior. Rust, Python, and JavaScript packages are versioned
0.2.0.
