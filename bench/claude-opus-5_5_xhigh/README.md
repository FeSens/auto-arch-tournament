# Claude Opus 5.5 xhigh: one completed repetition

<!--
DRAFT, prepared while launch 2 was in round 13 of 15. Every {{PLACEHOLDER}}
is filled from bench/claude-opus-5_5_xhigh/rep1/summary.json (the results
row) and rep1/log.jsonl once the run ends. Tables marked "regenerate" are
rebuilt from the final journal, see POST_RUN_CHECKLIST.md. Delete this
comment when finalizing.
-->

One repetition, 15 rounds with 3 candidate hypotheses per round: one baseline plus 45 candidate outcomes. It started from the same baseline as every other configuration, fitness 282.82.

| Repetition | Final / best fitness | Gain over baseline | Last improving round | Wall time |
|---|---:|---:|---:|---:|
| 1 | {{FINAL_FITNESS}} | {{DELTA_PCT}}% | {{LAST_IMPROVING_ROUND}} | {{WALL_TIME_SEC}} s |

**N=1.** This is a single measurement. Repeatability has not been measured, and no dispersion or model-to-model comparison can be computed from it. Treat any ranking against other configurations as untested. {{FINAL_FITNESS}} is the highest fitness recorded on this benchmark so far; with n=1 and the caveats below, that is a fact about this run, not evidence that this configuration is better than another.

Of the 45 candidates, {{N_IMPROVEMENTS}} were improvements, {{N_REGRESSIONS}} regressions and {{N_BROKEN}} broken. Most broken slots are hypothesis agents that hit the 20-minute limit without writing a hypothesis ({{N_HYPGEN_FAILED}} of 45, see "Candidate outcomes").

## Runtime and harness

- Runtime: Claude Code 2.1.282, model `claude-opus-5-5`, effort `xhigh`, subscription (OAuth) login. Configuration: `tools/bench/models-opus55-xhigh.yaml` (result name `claude-opus-5_5_xhigh`). N=15, K=3. Tool paths are in `rep1/env.json`.
- Harness: ref `fix/eval-hardening`, commit `132c378` (merged to main as `0920ae7`). The results row records `fixture_commit` `{{FIXTURE_COMMIT}}`, `runner_commit` `{{RUNNER_COMMIT}}`, `runner_dirty: {{RUNNER_DIRTY}}`. {{RUNNER_DIRTY_NOTE}} Candidate scoring is the same as for the other configurations: same fitness formula, gates, seeds [1, 2, 3], N=15, K=3. The integrity checks listed in [`gpt-6-sol_xhigh/README.md`](../gpt-6-sol_xhigh/README.md) apply here too. In addition, each clone carries a harness-only riscv-formal copy (`.tmp/riscv-formal-eval`) that agents cannot write. It is fingerprinted, and the worktree's `formal/riscv-formal` symlink is switched to it before the harness runs formal. Agents keep a writable copy for their own self-checks. {{SANDBOX_VIOLATIONS}} `sandbox_violation` outcomes occurred.
- Isolation (`tools/bench/runner.py` `claude_isolation_settings`; details and verification probes in `research/diary/2026-09-25.md`, section "Claude Code isolation"):
  - No user settings, plugins, hooks, MCP servers, connectors or auto-memory.
  - Bash runs in a sandbox with no network. Reads of `$HOME`, `/private/tmp` and other Claude sessions' temp dirs are denied. Writes are confined to the clone.
  - Web tools are disallowed, as in the Codex runs, along with tools that reach outside the rep.
  - The clone base is outside the repository, so Claude Code loads no parent `CLAUDE.md`.
  - Known differences from the Codex treatment: Claude's reads are stricter (Codex could read anywhere), `/tmp` writes are denied (Codex allowed them), and Claude session transcripts are written to the operator's `~/.claude/projects/`, which the agent cannot read. The diary section lists these.
- Cost: dollar billing is not available under OAuth. `total_cost_usd: 0.0` is not measured zero spend. `api_equivalent_cost_usd` ({{API_EQUIV_COST_USD}} USD) is Claude Code's own list-price estimate, not a bill.
- Tokens: {{TOKENS_IN}} in, {{TOKENS_OUT}} out. This harness archives implementer and scribe transcripts (the fix for the undercount described in the Sol README), so these totals cover all agents. Output tokens are a lower bound: sessions killed by the timeout report only streaming snapshots.
- `agent.log` is compacted the same way as for Sol: tool-output fields longer than 4 KB are cut to head and tail around a marker recording the original length and sha256. The verbatim transcript and the Git bundle are kept locally and not published.

## Launch history

The scored repetition is the second full launch, started 2026-09-26T03:22:40Z.

1. **Launch 1**, started 2026-09-25T20:26:45Z, stopped in round 8 by a harness bug. `formal/run_all.sh` reaps per-PID work dirs whose PID fails `kill -0`. Run by an agent inside the sandbox, where `kill -0` on outside processes fails, it deleted the harness's live formal work dir and caused a false `formal_failed`. The launch is kept, not scored, in [`aborted1-formal-reaper/`](aborted1-formal-reaper/NOTES.md). Its best journaled fitness was 601.32. It wrote no results row, and no journaled outcome of rounds 1 to 7 was changed by the bug.
2. **Fix and smoke tests.** Each clone now gets the harness-only riscv-formal copy described above. Smoke tests preceded launch 2. One smoke was stopped because the operator's login PATH resolved `sby` to `~/.local/bin/sby`; launches now prepend the toolchain bin. A later smoke ran the fixed harness end to end (a harness check only, not a result). See `research/diary/2026-09-26.md`.
3. **Launch 2**, started 2026-09-26T03:22:40Z on harness `132c378`, same configuration. This is the repetition reported here.

## Candidate outcomes

| Repetition | Improvements | Regressions | Hypothesis timeouts | Formal failures | Other broken | Candidates |
|---|---:|---:|---:|---:|---:|---:|
| 1 | {{N_IMPROVEMENTS}} | {{N_REGRESSIONS}} | {{N_HYPGEN_FAILED}} | {{N_FORMAL_FAILED}} | {{N_OTHER_BROKEN}} | 45 |

Hypothesis-agent timeouts are the dominant failure mode. A timeout is `hypothesis_gen_failed`: the hypothesis agent reached the 20-minute limit (`HYPOTHESIS_TIMEOUT_SEC=1200`) without writing a hypothesis. The agents spent that budget running their own synthesis and place-and-route experiments. Every model ran with the same limit. Through round 13 the count was 19 of 39. The one formal failure through round 13 (r13s2, speculating load-dependent branches) is a BMC counterexample: 7 of 53 checks failed (the six conditional-branch instruction checks and `pc_fwd_ch0`). {{FORMAL_FAILED_NOTE_AFTER_R13}}

Accepted designs, in order (regenerate from the final journal):

| Round, slot | Change (journal title, verbatim) | Fitness | LUT4 | Fmax median MHz |
|---|---|---:|---:|---:|
| r1s1 | Split EX into single-cycle integer ALU plus iterative DIV/REM unit | 359.01 | 5116 | 161.26 |
| r3s1 | Stall-only I-fetch replay store with registered next-PC lookahead | 438.47 | 5131 | 162.23 |
| r4s2 | Fetch predecode + 64-entry bimodal BHT stacked on the I-fetch replay-store core | 458.93 | 5600 | 156.35 |
| r5s0 | Pre-decoded one-hot ALU controls registered in ID/EX on the predictor core | 512.08 | 5560 | 174.46 |
| r7s0 | LUT-RAM register file + ID/EX control/data split + registered div b!=0 (Fmax 174 -> ~223 MHz, cycle-identical) | 643.41 | 3080 | 219.20 |
| r9s1 | Hide bus stalls on both sides: stall-only D-side store buffer + load cache, and a 4096-entry I-side replay store (netlist-identical to r7s0) | 695.16 | 3078 | 222.07 |
| r10s0 | Take the divider off every critical path: plain operand latch at start + two-phase registered restoring step (div_unit.sv only, cycle-neutral) | 859.77 | 3081 | 274.65 |
| r12s1 | Front-end storage restructure: BHT in distributed LUT-RAM + split 2x32 rvfi_order counter (draft) | 894.39 | 2826 | 285.71 |
{{ACCEPTED_ROWS_AFTER_R13}}

Final design: {{FINAL_LUT4}} LUT4, {{FINAL_FF}} FF, Fmax median {{FINAL_FMAX}} MHz (seeds {{FMAX_SEEDS}}), {{FINAL_CYCLES}} CoreMark cycles for 10 iterations.

The legacy `accepted: {{ACCEPTED_LEGACY}}` counter includes the baseline, so it is one higher than candidate improvements. In summary JSON, `best_round: {{BEST_ROUND_INDEX}}` is the journal entry index, not the tournament round. The last improving round above comes from the journal's `round_id`.

## Caveats on the accepted designs

The operator audited the accepted designs through r12s1{{AUDIT_SCOPE_AFTER_R13}}: changes are confined to `cores/bench/rtl/` and cocotb tests, no CoreMark-specific constants appear, and every design passed all gates. The fitness contract still leaves room for the following, so read the numbers with them in mind.

- **Stall-only hardware is free in the fitness metric.** CoreMark cycles are measured in simulation with about 22% random bus backpressure (`--istall --dstall`). Fmax and LUT4 come from `fpga/core_bench*.sv`, which ties the memory ready signals to 1. Logic that only acts while a ready is low is therefore constant-folded out of the timed netlist: its cycle savings count and its area and timing cost nothing. The r9s1 design exploits this (its title says "netlist-identical to r7s0"; it adds a 4096-entry I-side replay store and a load cache). Accepted designs of other configurations also contain stall-hiding structures. How much of any score comes from this is unmeasured; a proposed stall-free re-score has not been run. See `research/diary/2026-09-26.md`, "stall-only hardware".
- **Slower divider, cycle-neutral.** The r10s0 design made the divider a slower two-phase unit. That costs no cycles because CoreMark retires no divides in its timed window. The operator's independent Verilator test found 0 mismatches over 200,676 cases, with a maximum latency of 68 cycles.
- **Verification-only logic.** The r12s1 design partly optimizes the RVFI `rvfi_order` counter, which is verification-only logic the FPGA bench wrapper keeps in the timed design (the same pattern as Sol's r2s0).
- **LUT4 excludes RAM cells.** From r7s0 on, the register file is in LUT-RAM. The `lut4` column excludes LUT-RAM and block-RAM cells, so area figures are not directly comparable to designs with a flip-flop register file. {{FINAL_RAM_CELLS_NOTE}}

## Files

Per-repetition folder `rep1/` contains the canonical summaries (`summary.json`, `run_summary.json`), the full final journal (`log.jsonl`), the orchestrator log, the compacted agent transcript (`agent.log`) and the tool environment (`env.json`). The website and aggregate reports are generated from `bench/results.jsonl` and these journals. `aborted1-formal-reaper/` holds the stopped first launch.
