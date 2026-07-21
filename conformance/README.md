# Operon conformance suite

Conformance fixtures are deterministic command/event transcripts. Every SDK
must replay them and produce the declared command sequence and final result.
They test Operon behavior, not model quality, and require no live model.

Capability benchmarks live separately under `benchmarks/`.

`memory/` fixtures replay application-authored memory writes and lifecycle
operations against a local store. They verify scope filtering before ranking,
temporal supersession, tombstones, and that adversarial retrieved content is
rendered only as explicitly marked historical data.
