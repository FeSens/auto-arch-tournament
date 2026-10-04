# Final analysis, V2 campaign complete (2026-10-04 10:03Z)

Written when GPT-5.5's sixth run finished, the last run of the campaign. Every system has 6
scored runs (the GPT-6 Sol pilot has 1, unscored). These numbers are final: the primary and
amendment 01 verdicts match analysis_main_campaign_end.md, and the amendment 13 family now has
all 12 pairs, so its Holm p-values are final too.

Summary. The primary test separates Opus 5.5 from GPT-6.1 Sol (ratio 1.320, CI [1.183, 1.473],
p = 0.0005). Of the 12 extension pairs, 9 separate and 3 do not: Opus 5.5 vs Sonnet 5.5,
GPT-6.1 Sol vs GPT-6 Astra, and Luna vs GPT-5.5. The systems form three tiers, which the
rank intervals also show: {Opus 5.5, Sonnet 5.5} > {GPT-6.1 Sol, GPT-6 Astra} > {GPT-5.5, Luna}.
Every pair across tiers separates (Holm p 0.0000 to 0.0076). No pair within a tier does.

Amendment 12's correctness sensitivity analysis (step 2 on Opus rep2 and Sonnet 5.5 rep5) runs
after this; its outcome and the primary repeated without failing runs are reported separately.

Command: `python3 research/v2/scripts/analyze_main.py bench/v2/results.jsonl bench/v2/results-opus-luna.jsonl bench/v2/results-sol61.jsonl bench/v2/results-astra.jsonl bench/v2/results-sonnet55.jsonl bench/v2/results-gpt55.jsonl --rescored research/runs/EXP-2026-09-28-v2-main/incident_08/holdout_rescored.jsonl --json research/runs/EXP-2026-09-28-v2-main/analysis_final.json`

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
| GPT-5.5 | 1 | done | 3280.9 | runner | yes |
| Astra | 5 | done | 4546.4 | runner | yes |
| GPT-5.5 | 2 | done | 3781.9 | runner | yes |
| GPT-5.5 | 3 | done | 3216.0 | runner | yes |
| Astra | 6 | done | 5502.2 | runner | yes |
| GPT-5.5 | 4 | done | 3429.1 | runner | yes |
| GPT-5.5 | 5 | done | 4369.0 | runner | yes |
| GPT-5.5 | 6 | done | 3609.9 | runner | yes |

## Scored runs per system

| system | n | geomean held-out iter/s | SD of ln (run-to-run) |
|---|---|---|---|
| Opus | 6 | 7024.2 | 0.103 |
| Sol 6.1 | 6 | 5320.1 | 0.048 |
| Luna | 6 | 3538.0 | 0.151 |
| Astra | 6 | 5013.6 | 0.105 |
| Sonnet 5.5 | 6 | 6417.5 | 0.088 |
| GPT-5.5 | 6 | 3594.9 | 0.113 |

## Primary: Opus vs Sol 6.1 (Welch on ln held-out score)

ratio of geometric means 1.320, 95% CI [1.183, 1.473], bootstrap 95% CI [1.208, 1.427]; t = 5.99, df = 7.1, p = 0.0005
Verdict: Opus ranks higher than Sol 6.1 on this contract

## Secondary (amendment 01, Holm across the two)

Luna vs Sol 6.1: ratio 0.665, 95% CI [0.568, 0.779], bootstrap [0.591, 0.744]; p = 0.0007, Holm p = 0.0007. Sol 6.1 ranks higher than Luna on this contract
Luna vs Opus: ratio 0.504, 95% CI [0.425, 0.596], bootstrap [0.441, 0.574]; p = 0.0000, Holm p = 0.0000. Opus ranks higher than Luna on this contract

## Extension (amendment 13, Holm across the 12 pairs)

Opus vs Astra: ratio 1.401, 95% CI [1.225, 1.602], bootstrap [1.256, 1.553]; p = 0.0002, Holm p = 0.0018. Opus ranks higher than Astra on this contract
Opus vs Sonnet 5.5: ratio 1.095, 95% CI [0.967, 1.238], bootstrap [0.988, 1.205]; p = 0.1337, Holm p = 0.4010. not distinguishable at this n; no ranking claimed
Opus vs GPT-5.5: ratio 1.954, 95% CI [1.700, 2.246], bootstrap [1.735, 2.169]; p = 0.0000, Holm p = 0.0000. Opus ranks higher than GPT-5.5 on this contract
Sol 6.1 vs Astra: ratio 1.061, 95% CI [0.949, 1.187], bootstrap [0.978, 1.155]; p = 0.2500, Holm p = 0.4999. not distinguishable at this n; no ranking claimed
Sol 6.1 vs Sonnet 5.5: ratio 0.829, 95% CI [0.754, 0.911], bootstrap [0.770, 0.893]; p = 0.0019, Holm p = 0.0076. Sonnet 5.5 ranks higher than Sol 6.1 on this contract
Sol 6.1 vs GPT-5.5: ratio 1.480, 95% CI [1.314, 1.667], bootstrap [1.345, 1.607]; p = 0.0001, Holm p = 0.0011. Sol 6.1 ranks higher than GPT-5.5 on this contract
Luna vs Astra: ratio 0.706, 95% CI [0.595, 0.836], bootstrap [0.618, 0.805]; p = 0.0012, Holm p = 0.0074. Astra ranks higher than Luna on this contract
Luna vs Sonnet 5.5: ratio 0.551, 95% CI [0.468, 0.650], bootstrap [0.485, 0.625]; p = 0.0000, Holm p = 0.0003. Sonnet 5.5 ranks higher than Luna on this contract
Luna vs GPT-5.5: ratio 0.984, 95% CI [0.828, 1.170], bootstrap [0.858, 1.126]; p = 0.8402, Holm p = 0.8402. not distinguishable at this n; no ranking claimed
Astra vs Sonnet 5.5: ratio 0.781, 95% CI [0.689, 0.885], bootstrap [0.707, 0.862]; p = 0.0014, Holm p = 0.0074. Sonnet 5.5 ranks higher than Astra on this contract
Astra vs GPT-5.5: ratio 1.395, 95% CI [1.212, 1.605], bootstrap [1.243, 1.555]; p = 0.0004, Holm p = 0.0026. Astra ranks higher than GPT-5.5 on this contract
Sonnet 5.5 vs GPT-5.5: ratio 1.785, 95% CI [1.566, 2.035], bootstrap [1.606, 1.973]; p = 0.0000, Holm p = 0.0000. Sonnet 5.5 ranks higher than GPT-5.5 on this contract

## Descriptive ranking (amendment 13; 95% bootstrap rank interval)

| rank | system | n | geomean held-out iter/s | rank interval |
|---|---|---|---|---|
| 1 | Opus | 6 | 7024.2 | 1 to 2 |
| 2 | Sonnet 5.5 | 6 | 6417.5 | 1 to 2 |
| 3 | Sol 6.1 | 6 | 5320.1 | 3 to 4 |
| 4 | Astra | 6 | 5013.6 | 3 to 4 |
| 5 | GPT-5.5 | 6 | 3594.9 | 5 to 6 |
| 6 | Luna | 6 | 3538.0 | 5 to 6 |
