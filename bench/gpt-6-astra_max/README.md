# GPT-6 Astra max: three completed repetitions

All three repetitions completed 15 rounds with 3 candidate hypotheses per round. Each journal contains one baseline plus 45 unique candidate outcomes. Every repetition started independently from the same baseline, fitness 282.82.

| Repetition | Final / best fitness | Gain over baseline | Last improving round | Wall time |
|---|---:|---:|---:|---:|
| 1 | 388.66 | 37.42% | 5 | 42,827 s |
| 2 | 411.53 | 45.51% | 11 | 44,030 s |
| 3 | 474.27 | 67.69% | 14 | 43,518 s |

Mean endpoint fitness is **424.82**, sample SD **44.33** (N=3); peak fitness is **474.27**. The existing aggregate leaderboard uses population SD, **36.19**, which is a different statistic. The highest individual result in this published cohort remains GPT-5.5 xhigh rep2 at **525.04**; Astra's peak is **9.67%** below it. These runs measure the model with its recorded runtime and effort configuration.

## Runtime and recovery

- Runtime: Codex CLI 0.153.4, `gpt-6-astra`, reasoning effort `max`, ChatGPT OAuth. Configuration and tool paths are recorded per repetition.
- Harness source commit: `c1edd6161ffd6021c505d9db64020b0a3bf8e292`. Full local run clones and Git bundles are retained; bundles are excluded from this public artifact upload.
- Repetition 1 completed first. Repetitions 2 and 3 then ran in parallel, without sharing model state or winning designs.
- A usage-limit interruption affected rounds 12–15 of repetitions 2 and 3. Recovery preserved all valid outcomes through round 11 and the already evaluated rep2 round12 slot1 candidate. Only the 23 quota-blocked candidate slots were resumed. Synthetic quota placeholders were removed from the final journals; the original attempts remain archived locally. Prompts, candidate evaluation, correctness gates, and scoring were unchanged.
- The recorded wall times include the usage-limit pauses (2,797 s for rep2 and 2,786 s for rep3). Concurrent execution and runtime differences matter when comparing elapsed time with other configurations.
- Dollar billing was unavailable through OAuth. `total_cost_usd: 0.0` is the parser default, not measured zero spend. Token totals include the original and resumed runtime logs.
- The earlier baseline-only [startup environment incident](startup-attempt1/NOTES.md) made no model calls and is not a scored repetition.

## Candidate outcomes

| Repetition | Improvements | Regressions | Formal failures | Placement failures | Candidates |
|---|---:|---:|---:|---:|---:|
| 1 | 5 | 38 | 2 | 0 | 45 |
| 2 | 5 | 39 | 1 | 0 | 45 |
| 3 | 4 | 40 | 0 | 1 | 45 |
| Total | 14 | 117 | 3 | 1 | 135 |

Legacy `accepted` summary counts include the baseline, so they are one higher than candidate improvements. Rep3 round13 slot1 passed formal and co-simulation but could not be placed on the FPGA; all three placement seeds exhausted RAM16SDP4 resources. Its journal outcome is `placement_failed`, which the legacy `broken` summary counter does not include. The tables above account for all candidate outcomes without changing the recorded summaries.

In summary JSON, `best_round` is the journal entry index, not the tournament round. The last improving rounds above use journal `round_id`.

Per-repetition folders contain canonical summaries, full final journals, runtime logs, and configuration. The website and aggregate reports are generated from `bench/results.jsonl` and these journals.
