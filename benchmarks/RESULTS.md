# Benchmark results

## Qwen3 4B, 30-case development run

This is the first full development run of the versioned 30-case corpus. It used
Ollama with `qwen3:4b`, one repetition per case, protocol 1.0, and evaluator
1.2. The saved output was rescored after adding explicit handling for terse
numeric answers. It is useful engineering evidence, not yet a publication-grade
claim; repeated runs and human review are still required.

| Configuration | Decision | Complete | Citation consistency | Source recall | Median behavior |
| --- | ---: | ---: | ---: | ---: | --- |
| Question only | 30.0% | 6.7% | — | — | 1 call, 750 ms mean |
| All documents in prompt | 73.3% | 23.3% | 3.3% | 100.0% | 1 call, 578 ms mean |
| Operon, verification off | 83.3% | 56.7% | 16.7% | 96.7% | 2 calls, 1,951 ms mean |
| Operon full | 80.0% | 53.3% | 100.0% | 96.7% | 2 calls, 1,712 ms mean |

The most defensible conclusion is that decomposition plus focused local
context materially improved this model on the test corpus. Full Operon added a
reliable output and citation contract. Citation consistency is mechanical—it
means cited IDs exist and match the declared IDs, not that the cited passage
logically proves the answer.

The difference between verified and unverified decision scores is one case and
comes from separate stochastic generations, not from validation changing a
correct answer. Repetitions are needed before comparing those two percentages.

## What the failures taught us

The remaining full-runtime misses cluster into useful product work:

- arithmetic and threshold reasoning, such as separating reimbursable food
  from alcohol;
- terse but under-explained answers;
- contradictory prose containing both an allowed and denied conclusion;
- combining two sources when one establishes a rule and another establishes a
  fact; and
- versioned-policy exceptions.

The initial three-model smoke matrix found a more fundamental issue: a model
planner could say grounding was unnecessary even when the developer explicitly
attached documents. This caused dangerous misses on refund and emergency-stop
cases. The runtime contract now makes attached grounding authoritative; the
planner can refine retrieval but cannot veto it. In the repeated five-case
smoke run, Llama 3.1 8B's full-runtime decision score moved from 60% to 100%.
Because each smoke cell has only one sample, that number is a regression signal,
not a stable model ranking.

## Reproduce

```bash
PYTHONPATH=sdk/python/src:. python3 -m benchmarks.run \
  --model qwen3:4b \
  --repetitions 1
```

For a credible public result, run at least three repetitions, complete the full
2B–8B model matrix, and manually adjudicate every disagreement.
