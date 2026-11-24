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
| Sol 6.2 | 1 | done | 6595.8 | runner | yes |
| Astra 6.2 | 1 | done | 7095.2 | runner | yes |
| Astra 6.2 | 2 | done | 6244.8 | runner | yes |
| Sol 6.2 | 2 | done | 6595.2 | runner | yes |
| Astra 6.2 | 3 | done | 6982.2 | runner | yes |
| Sol 6.2 | 3 | done | 6638.9 | runner | yes |
| Astra 6.2 | 4 | done | 7633.1 | runner | yes |
| Sol 6.2 | 4 | done | 6761.2 | runner | yes |
| Astra 6.2 | 5 | done | 7127.3 | runner | yes |
| Sol 6.2 | 5 | done | 6107.5 | runner | yes |
| Sol 6.2 | 6 | done | 7526.5 | runner | yes |
| Astra 6.2 | 6 | done | 6711.7 | runner | yes |

## Scored runs per system

| system | n | geomean held-out iter/s | SD of ln (run-to-run) |
|---|---|---|---|
| Opus | 6 | 7024.2 | 0.103 |
| Sol 6.1 | 6 | 5320.1 | 0.048 |
| Luna | 6 | 3538.0 | 0.151 |
| Astra | 6 | 5013.6 | 0.105 |
| Sonnet 5.5 | 6 | 6417.5 | 0.088 |
| GPT-5.5 | 6 | 3594.9 | 0.113 |
| Astra 6.2 | 6 | 6952.7 | 0.067 |
| Sol 6.2 | 6 | 6691.3 | 0.067 |
| Fable 5.2 | 0 | nan | nan |

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

## Extension 2 (amendment 17, Holm across the 13 pairs; PROVISIONAL, without Fable 5.2)

Opus vs Astra 6.2: ratio 1.010, 95% CI [0.901, 1.133], bootstrap [0.918, 1.101]; p = 0.8434, Holm p = 1.0000. not distinguishable at this n; no ranking claimed
Opus vs Sol 6.2: ratio 1.050, 95% CI [0.936, 1.177], bootstrap [0.954, 1.142]; p = 0.3605, Holm p = 1.0000. not distinguishable at this n; no ranking claimed
Sol 6.1 vs Astra 6.2: ratio 0.765, 95% CI [0.709, 0.826], bootstrap [0.720, 0.812]; p = 0.0000, Holm p = 0.0002. Astra 6.2 ranks higher than Sol 6.1 on this contract
Sol 6.1 vs Sol 6.2: ratio 0.795, 95% CI [0.737, 0.858], bootstrap [0.746, 0.843]; p = 0.0001, Holm p = 0.0006. Sol 6.2 ranks higher than Sol 6.1 on this contract
Luna vs Astra 6.2: ratio 0.509, 95% CI [0.434, 0.597], bootstrap [0.450, 0.573]; p = 0.0000, Holm p = 0.0002. Astra 6.2 ranks higher than Luna on this contract
Luna vs Sol 6.2: ratio 0.529, 95% CI [0.451, 0.620], bootstrap [0.468, 0.593]; p = 0.0000, Holm p = 0.0003. Sol 6.2 ranks higher than Luna on this contract
Astra vs Astra 6.2: ratio 0.721, 95% CI [0.642, 0.810], bootstrap [0.658, 0.789]; p = 0.0002, Holm p = 0.0011. Astra 6.2 ranks higher than Astra on this contract
Astra vs Sol 6.2: ratio 0.749, 95% CI [0.667, 0.842], bootstrap [0.683, 0.818]; p = 0.0004, Holm p = 0.0023. Sol 6.2 ranks higher than Astra on this contract
Sonnet 5.5 vs Astra 6.2: ratio 0.923, 95% CI [0.834, 1.021], bootstrap [0.851, 1.001]; p = 0.1079, Holm p = 0.5393. not distinguishable at this n; no ranking claimed
Sonnet 5.5 vs Sol 6.2: ratio 0.959, 95% CI [0.867, 1.062], bootstrap [0.883, 1.038]; p = 0.3779, Holm p = 1.0000. not distinguishable at this n; no ranking claimed
GPT-5.5 vs Astra 6.2: ratio 0.517, 95% CI [0.457, 0.585], bootstrap [0.473, 0.573]; p = 0.0000, Holm p = 0.0000. Astra 6.2 ranks higher than GPT-5.5 on this contract
GPT-5.5 vs Sol 6.2: ratio 0.537, 95% CI [0.475, 0.608], bootstrap [0.490, 0.596]; p = 0.0000, Holm p = 0.0000. Sol 6.2 ranks higher than GPT-5.5 on this contract
Astra 6.2 vs Sol 6.2: ratio 1.039, 95% CI [0.953, 1.133], bootstrap [0.967, 1.112]; p = 0.3472, Holm p = 1.0000. not distinguishable at this n; no ranking claimed

## Descriptive ranking (amendment 13; 95% bootstrap rank interval)

| rank | system | n | geomean held-out iter/s | rank interval |
|---|---|---|---|---|
| 1 | Opus | 6 | 7024.2 | 1 to 4 |
| 2 | Astra 6.2 | 6 | 6952.7 | 1 to 3 |
| 3 | Sol 6.2 | 6 | 6691.3 | 1 to 4 |
| 4 | Sonnet 5.5 | 6 | 6417.5 | 2 to 4 |
| 5 | Sol 6.1 | 6 | 5320.1 | 5 to 6 |
| 6 | Astra | 6 | 5013.6 | 5 to 6 |
| 7 | GPT-5.5 | 6 | 3594.9 | 7 to 8 |
| 8 | Luna | 6 | 3538.0 | 7 to 8 |
