# Operon specifications

These documents define behavior shared across every language SDK. Package APIs
may remain idiomatic to their language, but they must produce protocol-compatible
commands, results, validation decisions, and traces.

- [Execution protocol](execution-protocol.md)
- [Trace format](trace-format.md)
- [Local context and memory architecture](../docs/research/local-memory-architecture.md)
- [Command/event architecture decision](../docs/adr/0001-command-event-core.md)
- [Command JSON Schema](schemas/execution-command.schema.json)
- [Event JSON Schema](schemas/execution-event.schema.json)
