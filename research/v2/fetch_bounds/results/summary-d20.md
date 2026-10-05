# Fetch-address bounds, BMC depth 20

| system | designs | PASS | FAIL | TIMEOUT | solver time, median s |
|---|---|---|---|---|---|
| Opus 5.5 | 6 | 2 | 1 | 3 | 341 |
| Sonnet 5.5 | 6 | 5 | 0 | 1 | 994 |
| GPT-6.1 Sol | 6 | 4 | 0 | 2 | 2150 |
| GPT-6 Astra | 6 | 6 | 0 | 0 | 2638 |
| GPT-5.5 | 6 | 6 | 0 | 0 | 344 |
| GPT-6 Luna | 6 | 6 | 0 | 0 | 321 |
| GPT-6.1 Sol, no lessons (ablation) | 6 | 6 | 0 | 0 | 789 |
| GPT-6 Sol pilot (unscored) | 1 | 0 | 0 | 1 |  |
| textbook edit | 1 | 1 | 0 | 0 | 203 |
| all | 44 | 36 | 1 | 7 | |

## Not passing

| design | outcome | step | fetch addresses (FAIL) or steps with no counterexample (TIMEOUT) |
|---|---|---|---|
| claude-opus-5_5_xhigh-v2_rep1 | TIMEOUT after 5400 s | | 0 to 11 |
| claude-opus-5_5_xhigh-v2_rep2 | TIMEOUT after 5400 s | | 0 to 18 |
| claude-opus-5_5_xhigh-v2_rep5 | TIMEOUT after 5400 s | | 0 to 11 |
| claude-opus-5_5_xhigh-v2_rep6 | FAIL | 9 | 0x0 0x0 0x0 0x4 0x8 0x0 0x0 0x4 0x0 0xfffffffc |
| claude-sonnet-5-5_xhigh-v2_rep4 | TIMEOUT after 5400 s | | 0 to 11 |
| gpt-6-sol_xhigh-v2_rep1 | TIMEOUT after 5400 s | | 0 to 14 |
| gpt-6_1-sol_xhigh-v2_rep1 | TIMEOUT after 5400 s | | 0 to 16 |
| gpt-6_1-sol_xhigh-v2_rep2 | TIMEOUT after 5400 s | | 0 to 14 |
