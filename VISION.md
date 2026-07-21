# Vision: the on-device intelligence runtime

The limiting factor for useful on-device AI is increasingly the runtime around
the model rather than the model alone.

A small language model cannot match a frontier model in general intelligence,
and it does not need to. A runtime can make many small decisions that constrain
the model's search space and improve the reliability, privacy, and efficiency
of the complete system.

Operon's thesis is:

> A constrained model becomes substantially more useful when planning,
> context, retrieval, tools, verification, repair, and resource policy are
> explicit runtime responsibilities.

## Product promise

Bring a local model, declare what it may access, and run a query. Operon should
provide immediate value without requiring the developer to design an agent
graph or retrieval pipeline.

The default experience remains:

```python
model = Operon.wrap(provider, grounding="./documents")
result = model.run(query)
```

Advanced applications may tune policies and replace components, but complexity
must be progressively disclosed.

## Principles

1. **Constrain before generating.** Reduce each operation to the smallest useful
   search space.
2. **Ground before asserting.** Retrieve only relevant, authorized context and
   preserve its provenance.
3. **Verify before returning.** Prefer deterministic checks and targeted repair
   over vague requests for the model to reconsider everything.
4. **Local is the default boundary.** Cloud use is an explicit, inspectable
   policy decision.
5. **Resources are part of correctness.** Context, latency, memory, energy, and
   thermal budgets influence execution decisions.
6. **The model is replaceable.** Operon depends on capabilities, not vendors or
   model families.
7. **Every decision is inspectable.** A developer can understand why retrieval,
   repair, a tool, or escalation occurred.

## Success

Operon succeeds when the same small model completes representative tasks more
reliably under Operon than through direct invocation, with measurable costs for
latency, tokens, memory, and energy.

