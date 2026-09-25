# GPT-6 Sol xhigh: one completed repetition

One repetition, 15 rounds with 3 candidate hypotheses per round: one baseline plus 45 candidate outcomes. It started from the same baseline as every other configuration, fitness 282.82.

| Repetition | Final / best fitness | Gain over baseline | Last improving round | Wall time |
|---|---:|---:|---:|---:|
| 1 | 435.24 | 53.89% | 14 | 23,546 s |

**N=1.** This is a single measurement. Repeatability has not been measured, and no dispersion or model-to-model comparison can be computed from it. Treat any ranking against other configurations as untested.

## Runtime and harness

- Runtime: Codex CLI 0.156.1, `gpt-6-sol`, reasoning effort `xhigh`, ChatGPT OAuth. Configuration: `tools/bench/models-gpt6-sol-xhigh.yaml`. Tool paths are in `rep1/env.json`.
- Harness: ref `fix/eval-hardening`, commit `1b5689180348b1a690f3d99aeee40865595ab992` (both `fixture_commit` and `runner_commit`, `runner_dirty: false`). This is a newer harness than the one used for the earlier published reps. Candidate scoring is unchanged: same fitness formula, gates, seeds [1, 2, 3], N=15, K=3. The changes are integrity checks and agent isolation:
  - Clone contract files, `formal/riscv-formal`, and the EDA binaries on PATH are fingerprinted before and after each implementation agent. Any change is `broken: sandbox_violation`. None occurred.
  - Gitignored build outputs in each candidate worktree are purged before evaluation.
  - A missing LUT4/DFF count in the FPGA report is now a failure, not a zero.
  - Formal runs take a machine-wide lock.
  - Published results, research notes, docs, the site and the paper are removed from the agent-visible clone.
  - Codex runs with an isolated `CODEX_HOME` (memories disabled, no login shell). It does not read `~/.codex` memories or config.

  Because of these isolation changes, this rep's agent had less access to prior results than the earlier Codex reps. That is a second difference besides the model, so a comparison against those reps is also non-attributable.
- Dollar billing is unavailable through OAuth. `total_cost_usd: 0.0` is the parser default, not measured zero spend. Tokens: 32,527,688 in, 592,247 out.
- `agent.log` is compacted: tool-output fields longer than 4 KB are cut to head and tail around a marker recording the original length and sha256. Model-authored text and usage events are unchanged. The verbatim transcript and the Git bundle are kept locally and not published.

## Launch history

Three earlier launches of this repetition were stopped before any candidate was evaluated. Each ran only the baseline retest, wrote no results row, and left no orphaned processes. The scored repetition is the fourth launch, started 2026-09-23T15:29:57Z.

1. 14:33Z: stopped on contamination. The clone exposed published results, and the agent read the operator's `~/.codex/memories` through the default `CODEX_HOME`.
2. 15:12Z: stopped. Placing the isolated `CODEX_HOME` under TMPDIR broke Codex's `apply_patch` helper aliases.
3. 15:17Z: stopped. Codex's login shell put an unrelated `sby` wrapper on the agent's PATH, and it failed on import.

The fixes for all three are in the harness commit above. Logs of the stopped launches are archived locally.

## Candidate outcomes

| Repetition | Improvements | Regressions | Formal failures | Placement failures | Candidates |
|---|---:|---:|---:|---:|---:|
| 1 | 5 | 40 | 0 | 0 | 45 |

Accepted designs, in order:

| Round, slot | Change | Fitness |
|---|---|---:|
| r1s1 | Decouple DIV and REM with an iterative EX unit | 349.32 |
| r2s0 | Segment the RVFI retirement order counter | 361.95 |
| r4s0 | Register one-hot ALU selects before execute | 392.16 |
| r6s0 | Clear only side-effect controls on ID/EX bubbles | 408.57 |
| r14s2 | Predict backward branches with low-byte PC steering | 435.24 |

Final design: 5713 LUT4, 2209 FF, Fmax median 188.61 MHz (seeds 174.52 / 188.61 / 190.62), 4,333,465 CoreMark cycles for 10 iterations.

The legacy `accepted: 6` counter includes the baseline, so it is one higher than candidate improvements. In summary JSON, `best_round: 43` is the journal entry index, not the tournament round. The last improving round above comes from the journal's `round_id`.

The r2s0 improvement changed verification-only RVFI logic, which the FPGA bench wrapper keeps in the timed design. See `research/diary/2026-09-23.md`.

Per-repetition folders contain canonical summaries, the full final journal, the orchestrator log, the compacted agent transcript and the tool environment. The website and aggregate reports are generated from `bench/results.jsonl` and these journals.
