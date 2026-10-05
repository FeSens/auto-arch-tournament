# Amendment 14: no-lessons ablation

## Scored runs

| arm | rep | harness | CoreMark | held-out iter/s | Fmax MHz | LUT4 | accepted / rejected / broken | wall h | tokens in (M) |
|---|---|---|---|---|---|---|---|---|---|
| Sol 6.1 (full) | 1 | 2.8.2 | 223.4 | 5472 | 93.7 | 3584 | 9 / 32 / 4 | 17.4 | 146 |
| Sol 6.1 (full) | 2 | 2.8.2 | 200.9 | 4940 | 81.6 | 4859 | 9 / 34 / 1 | 12.2 | 117 |
| Sol 6.1 (full) | 3 | 2.8.2 | 209.1 | 5079 | 85.6 | 6882 | 11 / 32 / 2 | 11.6 | 132 |
| Sol 6.1 (full) | 4 | 2.8.2 | 216.5 | 5512 | 87.7 | 5887 | 11 / 34 / 0 | 13.3 | 159 |
| Sol 6.1 (full) | 5 | 2.8.2 | 223.3 | 5528 | 96.0 | 6204 | 9 / 36 / 0 | 14.3 | 147 |
| Sol 6.1 (full) | 6 | 2.8.2 | 218.4 | 5420 | 93.8 | 3675 | 5 / 40 / 0 | 10.9 | 126 |
| Sol 6.1 (no lessons) | 1 | 2.8.3 | 174.9 | 4374 | 70.4 | 4312 | 8 / 37 / 0 | 10.3 | 126 |
| Sol 6.1 (no lessons) | 2 | 2.8.3 | 194.2 | 4958 | 81.5 | 4618 | 6 / 39 / 0 | 9.7 | 131 |
| Sol 6.1 (no lessons) | 3 | 2.8.3 | 238.3 | 5652 | 107.9 | 4462 | 9 / 36 / 0 | 10.3 | 150 |
| Sol 6.1 (no lessons) | 4 | 2.8.3 | 217.3 | 5320 | 91.2 | 4222 | 8 / 37 / 0 | 10.4 | 140 |
| Sol 6.1 (no lessons) | 5 | 2.8.3 | 220.5 | 5239 | 92.9 | 5044 | 10 / 35 / 0 | 9.5 | 131 |
| Sol 6.1 (no lessons) | 6 | 2.8.3 | 237.2 | 5875 | 97.4 | 3670 | 11 / 31 / 3 | 9.5 | 129 |

## Arms

| arm | n | geomean held-out | geomean CoreMark | mean Fmax | mean LUT4 | accepted / rejected / broken (slots) | broken by gate | mean wall h | mean tokens in (M) / out (M) |
|---|---|---|---|---|---|---|---|---|---|
| Sol 6.1 (full) | 6 | 5320 | 215.1 | 89.7 | 5182 | 54 / 208 / 7 | cosim_failed 1, formal_failed 5, sandbox_violation 1 | 13.3 | 138 / 1.77 |
| Sol 6.1 (no lessons) | 6 | 5213 | 212.5 | 90.2 | 4388 | 52 / 215 / 3 | formal_failed 1, hypothesis_gen_failed 2 | 9.9 | 135 / 1.82 |

## Test: full vs no lessons (Welch on ln held-out score)

ratio of geometric means (full / no lessons) 1.021, 95% CI [0.913, 1.140], bootstrap 95% CI [0.942, 1.114]; t = 0.43, df = 7.0, p = 0.6779
Verdict: not distinguishable at n=6
