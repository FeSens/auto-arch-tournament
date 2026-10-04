# Analysis 2: where candidates end

45 candidates per run (15 rounds x 3 slots), 270 per system, 1,620 overall. Counts, with the share of the system's candidates in parentheses.

| system | accepted | rejected_lost_to_sibling | rejected_below_margin | rejected_no_gain | hypothesis_gen_failed | sandbox_violation | formal_check_failed | formal_timeout | cosim_failed | placement_failed | gate failures |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Opus 5.5 | 42 (15.6%) | 39 (14.4%) | 37 (13.7%) | 147 (54.4%) | 0 (0.0%) | 0 (0.0%) | 0 (0.0%) | 4 (1.5%) | 0 (0.0%) | 1 (0.4%) | 5 (1.9%) |
| Sonnet 5.5 | 47 (17.4%) | 40 (14.8%) | 43 (15.9%) | 126 (46.7%) | 2 (0.7%) | 1 (0.4%) | 0 (0.0%) | 10 (3.7%) | 1 (0.4%) | 0 (0.0%) | 14 (5.2%) |
| GPT-6.1 Sol | 54 (20.0%) | 52 (19.3%) | 32 (11.9%) | 124 (45.9%) | 0 (0.0%) | 1 (0.4%) | 2 (0.7%) | 3 (1.1%) | 1 (0.4%) | 1 (0.4%) | 8 (3.0%) |
| GPT-6 Astra | 56 (20.7%) | 58 (21.5%) | 47 (17.4%) | 106 (39.3%) | 0 (0.0%) | 0 (0.0%) | 2 (0.7%) | 1 (0.4%) | 0 (0.0%) | 0 (0.0%) | 3 (1.1%) |
| GPT-5.5 | 28 (10.4%) | 8 (3.0%) | 40 (14.8%) | 177 (65.6%) | 0 (0.0%) | 0 (0.0%) | 2 (0.7%) | 1 (0.4%) | 5 (1.9%) | 9 (3.3%) | 17 (6.3%) |
| GPT-6 Luna | 24 (8.9%) | 6 (2.2%) | 58 (21.5%) | 164 (60.7%) | 1 (0.4%) | 0 (0.0%) | 9 (3.3%) | 0 (0.0%) | 1 (0.4%) | 7 (2.6%) | 18 (6.7%) |
| all | 251 (15.5%) | 203 (12.5%) | 257 (15.9%) | 844 (52.1%) | 3 (0.2%) | 2 (0.1%) | 15 (0.9%) | 19 (1.2%) | 8 (0.5%) | 18 (1.1%) | 65 (4.0%) |

Gate failures by the stage that stopped them (all systems):

| stage | candidates | share of gate failures |
|---|---|---|
| 1 hypothesis agent | 3 | 5% |
| 3 sandbox check | 2 | 3% |
| 5 formal | 34 | 52% |
| 6 cosim | 8 | 12% |
| 7 FPGA place and route | 18 | 28% |

Gate failures by stage per system:

| system | 1 hypothesis agent | 3 sandbox check | 5 formal | 6 cosim | 7 FPGA place and route |
|---|---|---|---|---|---|
| Opus 5.5 | 0 | 0 | 4 | 0 | 1 |
| Sonnet 5.5 | 2 | 1 | 10 | 1 | 0 |
| GPT-6.1 Sol | 0 | 1 | 5 | 1 | 1 |
| GPT-6 Astra | 0 | 0 | 3 | 0 | 0 |
| GPT-5.5 | 0 | 0 | 3 | 5 | 9 |
| GPT-6 Luna | 1 | 0 | 9 | 1 | 7 |

Check: per-run counts match every results row. The results rows count the baseline retest as accepted and count placement_failed candidates as neither rejected nor broken (accepted + rejected + broken = 46 minus placement failures); here placement_failed is a gate failure.
