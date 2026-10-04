# Analysis 3: implementation agents' own checks before submitting

1617 implementation sessions (36 runs x 45 slots, minus 3 slots whose hypothesis agent failed, so no implementation ran).

Share of implementation sessions that ran each check at least once:

| system | slots | formal | formal after last RTL edit | cosim | Gowin timing | cocotb | lint | own sim | formal+cosim+timing | killed at 30 min |
|---|---|---|---|---|---|---|---|---|---|---|
| Opus 5.5 | 270 | 99% | 69% | 100% | 83% | 82% | 100% | 2% | 83% | 0% |
| Sonnet 5.5 | 268 | 100% | 84% | 100% | 85% | 70% | 100% | 0% | 85% | 1% |
| GPT-6.1 Sol | 270 | 100% | 73% | 100% | 100% | 100% | 100% | 0% | 100% | 3% |
| GPT-6 Astra | 270 | 100% | 73% | 100% | 100% | 100% | 100% | 0% | 100% | 0% |
| GPT-5.5 | 270 | 100% | 96% | 99% | 1% | 67% | 100% | 0% | 1% | 0% |
| GPT-6 Luna | 269 | 100% | 83% | 97% | 88% | 12% | 100% | 0% | 88% | 4% |
| all | 1617 | 100% | 79% | 99% | 76% | 72% | 100% | 0% | 76% | 1% |

Gate failures (broken or placement_failed) by whether the session ran formal itself:

| system | slots with formal | gate-fail rate | formal-fail rate | slots without formal | gate-fail rate | formal-fail rate |
|---|---|---|---|---|---|---|
| Opus 5.5 | 267 | 2% | 1% | 3 | 0% | 0% |
| Sonnet 5.5 | 268 | 4% | 4% | 0 |  |  |
| GPT-6.1 Sol | 270 | 3% | 2% | 0 |  |  |
| GPT-6 Astra | 270 | 1% | 1% | 0 |  |  |
| GPT-5.5 | 270 | 6% | 1% | 0 |  |  |
| GPT-6 Luna | 269 | 6% | 3% | 0 |  |  |
| all | 1614 | 4% | 2% | 3 | 0% | 0% |

Formal-fail rate when the last formal self-check came after the last RTL edit vs not:

| system | slots formal after last edit | formal-fail rate | other slots | formal-fail rate |
|---|---|---|---|---|
| Opus 5.5 | 185 | 1% | 85 | 2% |
| Sonnet 5.5 | 225 | 4% | 43 | 2% |
| GPT-6.1 Sol | 197 | 2% | 73 | 1% |
| GPT-6 Astra | 196 | 0% | 74 | 4% |
| GPT-5.5 | 258 | 1% | 12 | 0% |
| GPT-6 Luna | 223 | 4% | 46 | 0% |
| all | 1284 | 2% | 333 | 2% |

Last local formal result the implementation agent saw (run_all.sh's "Formal: N passed, M failed" line in a command output), and how the slot then fared at the gates. pass_final: 0 failed, and both the run and the reading of its result came after the last RTL edit; pass_stale: 0 failed but the RTL changed afterwards; fail: the last result it saw had failures; none: it never saw a finished run.

| system | pass_final: n (formal-gate fails / other gate fails) | pass_stale: n (formal-gate fails / other gate fails) | fail: n (formal-gate fails / other gate fails) | none: n (formal-gate fails / other gate fails) |
|---|---|---|---|---|
| Opus 5.5 | 156 (0 / 0) | 74 (0 / 0) | 4 (1 / 0) | 36 (3 / 1) |
| Sonnet 5.5 | 199 (0 / 2) | 43 (0 / 0) | 2 (1 / 0) | 24 (9 / 0) |
| GPT-6.1 Sol | 192 (0 / 1) | 69 (0 / 1) | 4 (3 / 0) | 5 (2 / 1) |
| GPT-6 Astra | 189 (0 / 0) | 72 (0 / 0) | 2 (2 / 0) | 7 (1 / 0) |
| GPT-5.5 | 254 (0 / 11) | 12 (0 / 3) | 3 (2 / 0) | 1 (1 / 0) |
| GPT-6 Luna | 208 (0 / 5) | 49 (0 / 3) | 11 (9 / 0) | 1 (0 / 0) |
| all | 1198 (0 / 19) | 319 (0 / 7) | 26 (18 / 0) | 74 (16 / 2) |

Formal-gate failures by the agent's last local verdict:

| local verdict | gate class | n |
|---|---|---|
| fail | formal_check_failed | 15 |
| fail | formal_timeout | 3 |
| none | formal_timeout | 16 |

Failing slots by class and whether the implementation agent ran formal:

| system | class | ran formal | n |
|---|---|---|---|
| GPT-5.5 | cosim_failed | yes | 5 |
| GPT-5.5 | formal_check_failed | yes | 2 |
| GPT-5.5 | formal_timeout | yes | 1 |
| GPT-5.5 | placement_failed | yes | 9 |
| GPT-6 Astra | formal_check_failed | yes | 2 |
| GPT-6 Astra | formal_timeout | yes | 1 |
| GPT-6 Luna | cosim_failed | yes | 1 |
| GPT-6 Luna | formal_check_failed | yes | 9 |
| GPT-6 Luna | placement_failed | yes | 7 |
| GPT-6.1 Sol | cosim_failed | yes | 1 |
| GPT-6.1 Sol | formal_check_failed | yes | 2 |
| GPT-6.1 Sol | formal_timeout | yes | 3 |
| GPT-6.1 Sol | placement_failed | yes | 1 |
| GPT-6.1 Sol | sandbox_violation | yes | 1 |
| Opus 5.5 | formal_timeout | yes | 4 |
| Opus 5.5 | placement_failed | yes | 1 |
| Sonnet 5.5 | cosim_failed | yes | 1 |
| Sonnet 5.5 | formal_timeout | yes | 10 |
| Sonnet 5.5 | sandbox_violation | yes | 1 |

Hypothesis agents (they may probe ideas before proposing them):

| system | sessions | formal | cosim | Gowin timing | cocotb | killed at 20 min |
|---|---|---|---|---|---|---|
| Opus 5.5 | 270 | 0% | 1% | 35% | 0% | 0% |
| Sonnet 5.5 | 270 | 0% | 5% | 40% | 0% | 0% |
| GPT-6.1 Sol | 270 | 12% | 70% | 76% | 46% | 56% |
| GPT-6 Astra | 270 | 22% | 66% | 69% | 57% | 23% |
| GPT-5.5 | 270 | 0% | 0% | 0% | 0% | 0% |
| GPT-6 Luna | 270 | 0% | 0% | 0% | 0% | 0% |
