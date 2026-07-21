# Portable trace format

Trace events are ordered records with these fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `stage` | string | `classify`, `ground`, `generate`, `validate`, or `repair` |
| `message` | string | Stable human-readable event summary |
| `data` | object | Stage-specific structured metadata |
| `elapsed_ms` | number | Monotonic milliseconds since session start |

Traces must not include full source contents, prompts, model output, secrets, or
personal data by default. Hosts may provide an explicit diagnostic mode, but it
must be visibly separate from the safe default.

For durable memory, safe trace data includes record IDs, scope metadata, result
counts, and budget decisions. It must not include raw memory content by default.
