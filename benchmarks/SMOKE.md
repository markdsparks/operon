# Live smoke result

Date: 2026-07-21  
Model: `qwen3:4b` (`Q4_K_M`) through local Ollama  
Scenario: apply a company refund policy to a discounted, unopened item

This is an integration smoke test, not a statistically meaningful benchmark.

## Naive invocation

The model received the customer facts but no retrieved company policy. It:

- approved the refund;
- treated a presumed 30-day window as the controlling rule;
- asserted unsupported industry percentages; and
- generated policy-like language and source locations that were not supplied.

The decision was incorrect. The actual company policy says discounted and
clearance merchandise is final sale.

## Operon invocation

Operon:

1. classified the task and produced two focused subquestions;
2. retrieved `refund-policy.md` and `customer-request.md`;
3. produced the correct denial with `0.95` reported model confidence;
4. detected that the model declared two source IDs but omitted inline markers;
5. added the valid markers deterministically without another inference call;
6. returned the answer and full trace in approximately 1.43 seconds after
   model warm-up.

Result:

```text
The customer does not qualify for a refund. [S1] [S2]
```

## Finding

The result supports the project hypothesis for one grounded policy task: the
runtime corrected a confidently wrong ungrounded answer by constraining the
model with authorized local context, enforcing provenance, and repairing a
mechanical output failure outside the model.

The next benchmark must use a task suite, repeated runs, fixed decoding
parameters, latency/token accounting, and independent correctness labels.

