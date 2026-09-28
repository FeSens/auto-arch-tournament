# EXP-2026-09-28-v2-gowin-calibration: result

Ran as pre-registered on the run host (Gowin EDA 1.9.11.03 Education,
tools/eval/gowin.py, V2 wrapper), 9 designs x place_option 0/1/2 + a repeat
of option 0. Rows: runs.jsonl.

| design | p0 | p1 | p2 | score | SD ln over options | repeat equal |
|---|---|---|---|---|---|---|
| V0 | 5.140 | 5.442 | 5.442 | 5.442 | 0.0330 | yes |
| gpt-5_6-sol_rep1 | 5.131 | 5.391 | 5.391 | 5.391 | 0.0285 | yes |
| gpt-5_6-terra_rep3 | 4.989 | 5.001 | 5.001 | 5.001 | 0.0014 | yes |
| gpt-6-astra_max_rep1 | 27.717 | 28.445 | 28.445 | 28.445 | 0.0150 | yes |
| gpt-6-astra_max_rep2 | 44.418 | 44.809 | 44.809 | 44.809 | 0.0051 | yes |
| gpt-6-astra_max_rep3 | 23.853 | 25.588 | 25.588 | 25.588 | 0.0405 | yes |
| gpt-6-sol_xhigh_rep1 | 46.714 | 43.347 | 43.347 | 43.347 | 0.0432 | yes |
| smoke Opus 5.5 V2 champion | 50.285 | 47.738 | 47.738 | 47.738 | 0.0300 | yes |
| smoke GPT-6 Sol V2 champion | 33.225 | 32.658 | 32.658 | 32.658 | 0.0099 | yes |

sigma_opt (pooled, n=9) = 0.0272; sigma_score = 0.67 x 0.0272 = 0.0182;
2.33 x sigma_score = 0.0425 -> ACCEPT_MARGIN_LN = 0.045 (4.6%), as the rule
states. Reproducibility: 9/9 repeat builds identical.

Deviation from an assumption of the rule (reported, not acted on): options 1
and 2 gave identical results on every design, so the "median of 3" is always
option 1's value and the three options are not independent draws. If the
score is treated as a single draw (sigma_score = sigma_opt), the margin would
be 2.33 x 0.0272 = 0.063 (6.5%). The registered 4.6% is used.

Also measured (context): under Gowin the V1 GPT finals span 5.0 to 46.7 MHz;
three of them kept V0's single-cycle divider (~5 MHz). The ordering of V1
designs changes relative to nextpnr (e.g. gpt-5_6-sol_rep1 was 180.7 MHz
median under nextpnr, 5.4 under Gowin).
