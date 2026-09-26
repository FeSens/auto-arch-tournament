# Claude Opus 5.5 xhigh: stopped launch 1 (not a scored repetition)

This launch was stopped in round 8 of 15, when a harness bug was found. Nothing was written to `bench/results.jsonl`. The run is kept here because its partial journal holds the highest fitness any configuration has reached on this benchmark so far. It is a record, not a result: n=1, a partial run, and the harness was faulty from the moment the bug could trigger.

## Configuration

- Claude Code 2.1.282, `claude-opus-5-5`, effort `xhigh`, subscription login, isolated per `tools/bench/runner.py` `claude_isolation_settings`.
- Harness `fix/eval-hardening` at `9fefcfb`. N=15, K=3, launched 2026-09-25T20:26:45Z. Stopped with SIGTERM at 2026-09-26 ~02:13Z, during round 8. No processes were left behind.

## Why it was stopped

`formal/run_all.sh` starts by reaping per-PID work directories `formal/riscv-formal/cores/bench-<pid>`. It deletes any whose PID fails `kill -0`. In this clone, `formal/riscv-formal` is a per-clone copy inside the clone, so the Claude sandbox allowed agents to write to it. Inside the sandbox, `kill -0` on any process outside it fails with "operation not permitted" (verified by probe). So an agent's own formal self-check treated the harness's live formal run as stale and deleted its work directory.

Measured instance: round 8 slot 1. The harness's formal run (PID 91122) had every check reporting `pass`. The slot 2 implementer launched `run_all.sh` at 02:04:50Z. From 02:04:51Z every check's `make .../status` step failed, and the tally found no checks: `broken: formal_failed: make_failed_during_execution / no_checks_generated`. That slot's outcome never reached the journal, because the run was stopped before round 8 closed.

Rounds 1 to 7 recorded no formal failures, so no journaled outcome was changed by this bug. The deletion can only produce false failures, never false passes.

## Journal (rounds 0 to 7)

22 entries: the baseline plus 21 candidates.
- 4 candidate improvements. The legacy counter shows 5 because it includes the baseline.
- 6 regressions.
- 11 broken, all `hypothesis_gen_failed`: the hypothesis agent reached the 20-minute limit without writing a hypothesis.

| Round | Change | Fitness | LUT4 | Fmax median (seeds) | CoreMark cycles |
|---|---|---:|---:|---|---:|
| 0 | baseline | 282.82 | 9563 | 127.03 (128.72 / 127.03 / 123.02) | 4,491,485 |
| 1 | dual-source fetch (IF-local instruction replay store) | 384.42 | 9890 | 143.18 (144.99 / 137.93 / 143.18) | 3,724,611 |
| 3 | multi-cycle DIV/REM unit | 481.34 | 5141 | 179.28 (179.28 / 174.89 / 185.08) | 3,724,565 |
| 5 | posted store buffer + data replay store | 488.32 | 5119 | 171.00 (171.00 / 174.73 / 167.95) | 3,501,791 |
| 6 | register file in LUT-RAM (RAM16SDP4) | **601.32** | 2656 | 210.57 (206.06 / 222.82 / 210.57) | 3,501,791 |

Audits of the round 3, 5 and 6 winners, done during the run:
- They changed only allowed paths (`cores/bench/rtl/` and cocotb tests).
- No contract file changed, and none contains CoreMark-specific constants.
- An independent Verilator testbench checked the round 3 divider on 200,676 cases (all 4 ops, edge cases and random operands) with 0 mismatches.

The round 1 winner was not audited this way.

The `lut4` column excludes LUT-RAM and block-RAM. The final design also uses 32 RAM16SDP4 and 4 BSRAM cells.

Round 6 matched round 5's cycle count exactly. Its whole gain is Fmax (171.0 to 210.6 MHz), from removing the two 32-to-1 register-read mux trees.

## Telemetry

- Tokens: 256,150,063 input and at least 860,864 output. Output is a lower bound because killed sessions report only streaming snapshots.
- Claude Code's list-price estimate for the completed sessions is $51.82. It was not billed, because the run used the subscription.

## Files

- `log.jsonl`: the journal, rounds 0 to 7.
- `orchestrator.log`
- `runner.log`
- `run_summary.json`
- `agent.log`: every hypothesis, implementer and scribe transcript, compacted.
- `agent.full.log.gz` and `repo.bundle`: kept locally only (gitignored or too large to publish).

The full clone is kept at `aat-bench-runs/claude-opus-5_5_xhigh-rep1.aborted1-formal-reaper`.
