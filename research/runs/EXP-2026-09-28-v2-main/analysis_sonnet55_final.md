# Analysis at Sonnet 5.5 completion (2026-10-03 08:54Z)

Written when Sonnet 5.5's sixth run finished. The main family (primary and amendment 01) is unchanged from analysis_main_campaign_end.md. Sonnet 5.5's amendment 13 family (its three pairs against the main systems, Holm across the three) is final here because all four systems in it have 6 scored runs. Astra (4 of 6) and GPT-5.5 (0 of 6) are still running; the descriptive ranking row for Astra is interim.

Command: `python3 research/v2/scripts/analyze_main.py bench/v2/results.jsonl bench/v2/results-opus-luna.jsonl bench/v2/results-sol61.jsonl bench/v2/results-astra.jsonl bench/v2/results-sonnet55.jsonl --rescored research/runs/EXP-2026-09-28-v2-main/incident_08/holdout_rescored.jsonl`

## Attempts (order of completion)

| system | rep | status | held-out iter/s | held-out source | scored |
|---|---|---|---|---|---|
| Opus | 1 | done | 7769.6 | rescored (holdout_rescored.jsonl) | yes |
| GPT-6 Sol (pilot) | 1 | done | 5767.6 | rescored (holdout_rescored.jsonl) | pilot |
| Luna | 1 | done | 3042.7 | rescored (holdout_rescored.jsonl) | yes |
| GPT-6 Sol (pilot) | 2 | failed |  |  | pilot |
| Luna | 2 | failed |  |  |  |
| Opus | 2 | failed |  |  |  |
| Luna | 2 | done | 3849.5 | runner | yes |
| Opus | 2 | done | 7318.2 | runner | yes |
| Luna | 3 | done | 4038.9 | runner | yes |
| Sol 6.1 | 1 | done | 5472.0 | runner | yes |
| Opus | 3 | done | 6377.8 | runner | yes |
| Opus | 4 | done | 5990.8 | runner | yes |
| Luna | 4 | done | 3488.4 | runner | yes |
| Sol 6.1 | 2 | done | 4940.4 | runner | yes |
| Opus | 5 | done | 7483.9 | runner | yes |
| Luna | 5 | done | 4125.9 | runner | yes |
| Opus | 6 | done | 7387.4 | runner | yes |
| Luna | 6 | done | 2880.7 | runner | yes |
| Sol 6.1 | 3 | done | 5079.1 | runner | yes |
| Sonnet 5.5 | 1 | done | 5641.5 | runner | yes |
| Astra | 1 | done | 4352.6 | runner | yes |
| Sonnet 5.5 | 2 | done | 6030.8 | runner | yes |
| Sol 6.1 | 4 | done | 5511.7 | runner | yes |
| Astra | 2 | done | 5288.7 | runner | yes |
| Sonnet 5.5 | 3 | done | 6920.5 | runner | yes |
| Sol 6.1 | 5 | done | 5527.5 | runner | yes |
| Astra | 3 | done | 5641.1 | runner | yes |
| Sonnet 5.5 | 4 | done | 7144.1 | runner | yes |
| Sonnet 5.5 | 5 | done | 6327.4 | runner | yes |
| Astra | 4 | done | 4889.2 | runner | yes |
| Sol 6.1 | 6 | done | 5419.8 | runner | yes |
| Sonnet 5.5 | 6 | done | 6563.4 | runner | yes |

## Scored runs per system

| system | n | geomean held-out iter/s | SD of ln (run-to-run) |
|---|---|---|---|
| Opus | 6 | 7024.2 | 0.103 |
| Sol 6.1 | 6 | 5320.1 | 0.048 |
| Luna | 6 | 3538.0 | 0.151 |
| Astra | 4 | 5019.7 | 0.112 |
| Sonnet 5.5 | 6 | 6417.5 | 0.088 |
| GPT-5.5 | 0 | nan | nan |

## Primary: Opus vs Sol 6.1 (Welch on ln held-out score)

ratio of geometric means 1.320, 95% CI [1.183, 1.473], bootstrap 95% CI [1.208, 1.427]; t = 5.99, df = 7.1, p = 0.0005
Verdict: Opus ranks higher than Sol 6.1 on this contract

## Secondary (amendment 01, Holm across the two)

Luna vs Sol 6.1: ratio 0.665, 95% CI [0.568, 0.779], bootstrap [0.591, 0.744]; p = 0.0007, Holm p = 0.0007. Sol 6.1 ranks higher than Luna on this contract
Luna vs Opus: ratio 0.504, 95% CI [0.425, 0.596], bootstrap [0.441, 0.574]; p = 0.0000, Holm p = 0.0000. Opus ranks higher than Luna on this contract

## Extension (amendment 13, Holm across the 3 pairs)

Opus vs Sonnet 5.5: ratio 1.095, 95% CI [0.967, 1.238], bootstrap [0.988, 1.205]; p = 0.1337, Holm p = 0.1337. not distinguishable at this n; no ranking claimed
Sol 6.1 vs Sonnet 5.5: ratio 0.829, 95% CI [0.754, 0.911], bootstrap [0.770, 0.893]; p = 0.0019, Holm p = 0.0038. Sonnet 5.5 ranks higher than Sol 6.1 on this contract
Luna vs Sonnet 5.5: ratio 0.551, 95% CI [0.468, 0.650], bootstrap [0.485, 0.625]; p = 0.0000, Holm p = 0.0001. Sonnet 5.5 ranks higher than Luna on this contract

Extension: not yet 6 scored runs for Astra; their pairs are left out.

## Descriptive ranking (amendment 13; 95% bootstrap rank interval)

| rank | system | n | geomean held-out iter/s | rank interval |
|---|---|---|---|---|
| 1 | Opus | 6 | 7024.2 | 1 to 2 |
| 2 | Sonnet 5.5 | 6 | 6417.5 | 1 to 2 |
| 3 | Sol 6.1 | 6 | 5320.1 | 3 to 4 |
| 4 | Astra | 4 | 5019.7 | 3 to 4 |
| 5 | Luna | 6 | 3538.0 | 5 to 5 |
