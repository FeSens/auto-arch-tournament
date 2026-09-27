# HWE Bench V2 plan

Branch: `v2`. Started 2026-09-27. Source of the requirements: the limitations measured in the V1 paper (`paper/arxiv/main.tex`, Sections 6 and 7).

## Decisions (operator, 2026-09-27)

| Question | Decision |
|---|---|
| Primary question | Compare agent systems: which vendor systems improve the core most under a fixed budget. |
| Unit of comparison | A model inside its vendor's native CLI (Codex CLI, Claude Code, ...). Claims name the system, never the bare model. Runtime is part of the treatment, not a confound to fix. |
| Stall model | The same pseudo-random stall generator drives the memory-ready signals in simulation and inside the timed FPGA wrapper. |
| Headline metric | Final champion's score on the hidden held-out suite. CoreMark stays the optimization signal the agent sees. |

## What V2 changes, mapped to V1 limitations

| V1 limitation | V2 change | Phase |
|---|---|---|
| Stall-only logic free (cycles from a stalling sim, Fmax from a never-stalling netlist) | Stall generator in `fpga/core_bench*.sv`, registered, same xorshift as `test/cosim/main.cpp` | 1 |
| RVFI verification logic is timed | Timed wrapper observes only memory-side outputs; RVFI unconnected and pruned | 1 |
| No acceptance margin; seed spread median 7.6% | Calibrate placement noise, then 5 seeds and a margin set from the calibration | 1 |
| CoreMark visible, transfer unmeasured | Held-out 5-kernel suite, hidden from agents, scored on every final champion; headline metric | 1 |
| LUT4 omits RAM/DSP | Report LUT4, FF, LUT-RAM, BSRAM, DSP for every candidate (secondary, not scored) | 1 |
| Instruction-level cosim ran without stalls, on a 115-instruction program | Trace cosim now also runs under the scoring stall pattern (done). Add a longer self-checking program (random instruction streams incl. M-extension and load/store/branch mixes) to the trace set | 1 |
| Arithmetic tests not a gate | Protected `test_alu.py` runs as a gate; full (non-ALTOPS) formal on each final champion | 1 |
| nextpnr can hang a rep | Per-seed timeout, recorded as a failed seed | 1 |
| Isolation differs across runtimes | One sandbox policy for every CLI: network only to the model API, stripped clone, same read/write rules | 1 |
| 25 of 32 final designs unrecoverable | Archive final RTL + per-attempt diffs for every run | 1 |
| Token/cost telemetry partial | Collect all agents' transcripts; API-key billing where the CLI supports it | 1 |
| Harness revision unknown for early runs | Tagged harness release + toolchain digest in every results row; any change = new version | 1 |
| Hypothesis agents timing out (Opus: 22/45) | Prompt states the time budget and requires an early complete draft (harness already keeps a draft written before timeout) | 1 |
| Few runs per configuration | Pilot measures SD, power calculation fixes n; target 4 to 6 systems, >= 8 runs each | 2, 3 |
| Weak controls | Replace with: single-textbook-edit baseline; one no-lessons ablation on one system | 3 |
| Static / random-mutation runs | Become harness CI tests, not benchmark runs | 1 |

Out of scope for V2 (stated as limitations): a second starting core, a second FPGA family, board-level measurement.

## Phases

**Phase 1: fix and validate the score (no model calls).**
1. Wrapper stall generator + RVFI removal (both wrappers).
2. nextpnr per-seed timeout.
3. Area reporting incl. RAM/DSP.
4. Arithmetic gate from the protected test copy.
5. Held-out scoring on every final champion; full RTL archive per run.
6. Prompt changes (below), identical for every system.
7. Isolation parity across CLIs; telemetry for all agents.
8. Harness version tag + toolchain digest in results rows.
9. Validation (gate 5):
   - V0 re-scored under V2; old vs new numbers recorded.
   - The 8 recoverable V1 designs re-scored under V2 (continuity table).
   - Trivially broken design scores / fails as expected.
   - Placement-noise calibration: V0 and 3 archived designs, >= 10 seeds each, plus netlist-neutral perturbations. Sets seed count and acceptance margin.
   - Static and random-mutation checks rerun as automated harness tests.

**Phase 2: pilot.** One system, 3 runs, V2 harness frozen. Measures run-level SD of the headline metric. Power calculation picks n. Not reported as a result.

**Phase 3: pre-register and run.** `research/runs/<id>/prereg.yaml` (write-once): systems, n, seeds/launch order, primary metric, test (e.g. pairwise bootstrap CI on held-out score, Holm-corrected), budget and timeouts, incident/retry policy. Then the main matrix, the textbook-edit baseline, and the no-lessons ablation.

**Phase 4: paper.** Drafted alongside Phase 3. One question, one primary metric, at most four claims, each tied to a pre-registered test.

## Prompt changes (Phase 1, frozen before the pilot)

Evidence from V1 runs:
- Opus 5.5: 22/45 hypothesis agents hit the 20-minute limit without writing a file; they were running their own synthesis/P&R sweeps. The harness already accepts a file written before the timeout.
- Co-simulation failures: 90 of 1,440 attempts; the implementation prompt asks for lint and formal self-checks but not co-simulation.
- Codex agents copied 140 to 225 MB of riscv-formal into scratch per self-check; shared `/tmp` writes.
- Small accepted gains (16 of 136 below 1%) are within placement noise.

Changes:
- Hypothesis prompt: state the time limit; require a complete, schema-valid YAML within the first few minutes, then refine it in place; any experiment must fit the remaining time; one nextpnr seed takes minutes.
- Hypothesis and implementation prompts: state the acceptance margin, so sub-noise proposals are known to be pointless.
- Implementation prompt: one provided self-check command covering lint, formal, co-simulation and a single-seed P&R, run in the clone's scratch dir.
- Both prompts: describe the V2 timing wrapper (stall generator present, RVFI not timed) so agents reason about the scored circuit.
- Fix the implementation timeout comment (value is 30 min).

All prompt text is part of the harness version and identical for every system.
