# Analysis 1: effort vs held-out score

Per system: median (min to max) over its 6 runs. Tokens are gross (input includes cache reads; output includes reasoning). API-equivalent cost exists only for Claude Code runs; every run's billed cost (total_cost_usd) is 0 because all runs used subscriptions.

| system | input tokens (M) | output tokens (M) | wall clock (h) | API-equivalent cost (USD) | Codex sessions killed without usage | held-out iter/s |
|---|---|---|---|---|---|---|
| Opus 5.5 | 212.8 (202.7 to 232.2) | 3.20 (3.14 to 3.32) | 6.8 (5.5 to 9.2) | 199 (193 to 203) | 0 (0 to 0) | 7,353 (5,991 to 7,770) |
| Sonnet 5.5 | 214.0 (194.1 to 249.9) | 3.01 (2.79 to 3.25) | 7.8 (6.7 to 9.3) | 115 (106 to 126) | 0 (0 to 0) | 6,445 (5,642 to 7,144) |
| GPT-6.1 Sol | 139.0 (116.9 to 158.9) | 1.77 (1.47 to 2.04) | 12.8 (10.9 to 17.4) | n/a | 28 (22 to 32) | 5,446 (4,940 to 5,528) |
| GPT-6 Astra | 165.6 (133.2 to 190.9) | 1.89 (1.46 to 2.17) | 10.8 (8.6 to 12.4) | n/a | 10 (5 to 19) | 5,089 (4,353 to 5,641) |
| GPT-5.5 | 109.9 (104.7 to 137.8) | 2.07 (1.82 to 2.34) | 4.9 (4.0 to 7.2) | n/a | 0 (0 to 0) | 3,520 (3,216 to 4,369) |
| GPT-6 Luna | 115.2 (94.5 to 143.7) | 1.88 (1.67 to 2.19) | 7.5 (6.0 to 7.8) | n/a | 1 (0 to 4) | 3,669 (2,881 to 4,126) |

Share of input tokens by agent role (summed over the 6 runs):

| system | hypothesis | implementation | scribe |
|---|---|---|---|
| Opus 5.5 | 19% | 75% | 6% |
| Sonnet 5.5 | 20% | 77% | 3% |
| GPT-6.1 Sol | 22% | 74% | 4% |
| GPT-6 Astra | 41% | 56% | 3% |
| GPT-5.5 | 14% | 83% | 3% |
| GPT-6 Luna | 12% | 86% | 3% |

Adjusted totals (killed Codex sessions imputed at the median finished session of the same system and role):

| system | input tokens (M), adjusted | output tokens (M), adjusted |
|---|---|---|
| Opus 5.5 | 212.8 (202.7 to 232.2) | 3.20 (3.14 to 3.32) |
| Sonnet 5.5 | 214.0 (194.1 to 249.9) | 3.01 (2.79 to 3.25) |
| GPT-6.1 Sol | 176.8 (159.5 to 187.8) | 2.38 (2.13 to 2.49) |
| GPT-6 Astra | 190.5 (171.0 to 204.7) | 2.16 (1.91 to 2.30) |
| GPT-5.5 | 109.9 (104.7 to 137.8) | 2.07 (1.82 to 2.34) |
| GPT-6 Luna | 119.7 (96.3 to 143.7) | 1.94 (1.70 to 2.20) |

Spearman rho between effort and held-out score (permutation p-value):

| metric | pooled, 36 runs | within-system ranks, 36 runs | Opus 5.5 | Sonnet 5.5 | GPT-6.1 Sol | GPT-6 Astra | GPT-5.5 | GPT-6 Luna |
|---|---|---|---|---|---|---|---|---|
| input tokens (M) | +0.83 (p<0.0001) | +0.01 (p=0.978) | +0.60 (p=0.242) | +0.09 (p=0.919) | +0.89 (p=0.033) | -0.60 (p=0.242) | -0.83 (p=0.058) | -0.09 (p=0.919) |
| output tokens (M) | +0.55 (p=0.001) | -0.01 (p=0.978) | +0.83 (p=0.058) | -0.37 (p=0.497) | +0.77 (p=0.103) | -0.49 (p=0.356) | -0.54 (p=0.297) | -0.26 (p=0.658) |
| input tokens, killed Codex sessions imputed (M) | +0.85 (p<0.0001) | +0.02 (p=0.932) | +0.60 (p=0.242) | +0.09 (p=0.919) | +0.89 (p=0.033) | -0.54 (p=0.297) | -0.83 (p=0.058) | -0.09 (p=0.919) |
| output tokens, killed Codex sessions imputed (M) | +0.79 (p<0.0001) | -0.08 (p=0.674) | +0.83 (p=0.058) | -0.37 (p=0.497) | +0.71 (p=0.136) | -0.83 (p=0.058) | -0.54 (p=0.297) | -0.26 (p=0.658) |
| wall clock (h) | +0.22 (p=0.196) | +0.14 (p=0.425) | +0.09 (p=0.919) | +0.14 (p=0.803) | +0.60 (p=0.242) | -0.09 (p=0.919) | -0.43 (p=0.419) | +0.54 (p=0.297) |
| API-equivalent cost (Claude runs only; pooled = 12 runs) | +0.52 (p=0.090) | +0.23 (p=0.497) | +0.60 (p=0.242) | -0.14 (p=0.803) | n/a | n/a | n/a | n/a |

Per run:

| system | rep | input (M) | output (M) | killed Codex sessions | wall (h) | API-eq. cost | held-out |
|---|---|---|---|---|---|---|---|
| Opus 5.5 | 1 | 216.2 | 3.29 | 0 | 6.6 | 201 | 7770 |
| Opus 5.5 | 2 | 202.7 | 3.18 | 0 | 9.2 | 193 | 7318 |
| Opus 5.5 | 3 | 208.8 | 3.15 | 0 | 8.3 | 193 | 6378 |
| Opus 5.5 | 4 | 209.3 | 3.14 | 0 | 5.5 | 196 | 5991 |
| Opus 5.5 | 5 | 232.2 | 3.22 | 0 | 7.0 | 203 | 7484 |
| Opus 5.5 | 6 | 218.6 | 3.32 | 0 | 5.8 | 202 | 7387 |
| Sonnet 5.5 | 1 | 194.1 | 2.92 | 0 | 6.7 | 109 | 5642 |
| Sonnet 5.5 | 2 | 249.9 | 3.18 | 0 | 9.3 | 126 | 6031 |
| Sonnet 5.5 | 3 | 210.0 | 3.09 | 0 | 7.1 | 115 | 6921 |
| Sonnet 5.5 | 4 | 217.9 | 2.89 | 0 | 8.3 | 114 | 7144 |
| Sonnet 5.5 | 5 | 235.5 | 3.25 | 0 | 7.3 | 125 | 6327 |
| Sonnet 5.5 | 6 | 196.0 | 2.79 | 0 | 8.9 | 106 | 6563 |
| GPT-6.1 Sol | 1 | 146.4 | 1.94 | 25 | 17.4 |  | 5472 |
| GPT-6.1 Sol | 2 | 116.9 | 1.47 | 32 | 12.2 |  | 4940 |
| GPT-6.1 Sol | 3 | 131.6 | 1.71 | 28 | 11.6 |  | 5079 |
| GPT-6.1 Sol | 4 | 158.9 | 2.04 | 22 | 13.3 |  | 5512 |
| GPT-6.1 Sol | 5 | 146.6 | 1.82 | 29 | 14.3 |  | 5528 |
| GPT-6.1 Sol | 6 | 126.2 | 1.64 | 27 | 10.9 |  | 5420 |
| GPT-6 Astra | 1 | 190.9 | 2.17 | 5 | 9.5 |  | 4353 |
| GPT-6 Astra | 2 | 189.7 | 2.08 | 8 | 11.2 |  | 5289 |
| GPT-6 Astra | 3 | 133.2 | 1.46 | 19 | 11.0 |  | 5641 |
| GPT-6 Astra | 4 | 172.9 | 1.88 | 11 | 10.7 |  | 4889 |
| GPT-6 Astra | 5 | 151.0 | 1.77 | 16 | 12.4 |  | 4546 |
| GPT-6 Astra | 6 | 158.2 | 1.89 | 6 | 8.6 |  | 5502 |
| GPT-5.5 | 1 | 137.8 | 2.34 | 0 | 7.2 |  | 3281 |
| GPT-5.5 | 2 | 105.7 | 1.82 | 0 | 5.4 |  | 3782 |
| GPT-5.5 | 3 | 112.5 | 2.00 | 0 | 4.4 |  | 3216 |
| GPT-5.5 | 4 | 123.9 | 2.14 | 0 | 5.4 |  | 3429 |
| GPT-5.5 | 5 | 104.7 | 1.96 | 0 | 4.0 |  | 4369 |
| GPT-5.5 | 6 | 107.3 | 2.15 | 0 | 4.1 |  | 3610 |
| GPT-6 Luna | 1 | 100.9 | 1.78 | 4 | 7.8 |  | 3043 |
| GPT-6 Luna | 2 | 94.5 | 1.67 | 1 | 7.4 |  | 3850 |
| GPT-6 Luna | 3 | 130.2 | 2.19 | 1 | 7.8 |  | 4039 |
| GPT-6 Luna | 4 | 112.7 | 1.99 | 1 | 6.2 |  | 3488 |
| GPT-6 Luna | 5 | 117.7 | 1.77 | 4 | 7.6 |  | 4126 |
| GPT-6 Luna | 6 | 143.7 | 2.18 | 0 | 6.0 |  | 2881 |
