# HWE Bench V2 notes

Append-only. Plan: `PLAN.md`. Branch `v2`.

## 2026-09-27

### Stall generator in the timed wrapper (measured)
- `fpga/bench_stall_gen.sv` reproduces `test/cosim/main.cpp`'s backpressure (xorshift32, seed 0xDEADBEEF, imem draw then dmem draw per cycle, accept when `(s & 0x7F) < 100`) from registers. `tools/eval/test_bench_stall_gen.py`: identical to the C++ model for 100,000 cycles; accept rate on each port within 0.76 to 0.80.
- Standalone synthesis: 34 DFF, about 90 small LUTs, constant for every design.
- Both wrappers now drive `io_imemReady` / `io_dmemReady` from it, and the LED observes only memory-side outputs, so RVFI-only logic is pruned.
- Yosys rejects `return` in functions; the module uses Verilog-2005 function assignment.

### Instruction-level cosim gap (measured)
- `selftest.elf` retires 115 instructions. Before today it ran only without stalls; the CoreMark check (CRCs only) was the only stalled run.
- `tools/eval/cosim.py` now runs every trace ELF twice (no stalls; `--istall --dstall`). V0 and the Opus 5.5 final design pass both.
- Still open: a longer self-checking trace program (PLAN.md).

### Placement depends on file paths, not only on the circuit (measured, n=1 design)
- V0, same RTL, same toolchain binaries, seeds 1/2/3:
  - exact harness invocation (repo-relative paths, V1 `synth.tcl`): 128.72 / 127.03 / 123.02 MHz, LUT4 9563. Identical to every V1 retest.
  - absolute scratch paths, V2 `synth.tcl` (reads one extra, unused module): 142.71 / 118.58 / 132.43 MHz, LUT4 9913.
- Median moved 127.03 to 132.43 (+4.3%) with no change to the circuit. Two things changed at once (paths, extra module read), so the cause is not attributed to either.
- Consequences:
  - All comparisons must use the harness's exact relative-path invocation (`scripts/wrapper_compare.sh` now builds a repo-shaped tree).
  - Supports the V1 limitation that acceptance without a margin admits placement luck. The Phase 1 noise calibration should include netlist-neutral perturbations of this kind (renamed files, reordered reads, renamed signals), not only extra seeds.

### Other Phase 1 changes (tests pass: 344 passed, 2 skipped)
- nextpnr per-seed timeout (`NEXTPNR_TIMEOUT_SEC = 2700`), counted as a failed seed; test uses a hanging stand-in script and checks no process is left.
- FPGA results record LUT-RAM, BSRAM and DSP cells next to LUT4/DFF.
- Runner copies each run's final RTL to `final-rtl/` and stores the held-out geomean (`holdout_geomean_iter_s`) in the results row; scoring errors are recorded, not raised.
- Prompts: hypothesis agent gets its time budget and must write a complete draft within 5 minutes; implementation agent gets its budget, the fact that partial work is evaluated as-is, and a `make cosim` self-check.
- Pre-existing, unrelated: `tools/bench/test_provenance.py::test_provenance_records_commits_and_dirty` fails on `git tag` in a temp repo on this machine, with and without these changes.

### V1 vs V2 timing harness, repo-shaped invocation (measured, seeds 1/2/3)
`scripts/wrapper_compare.sh` (repo-relative paths). The V1 rows reproduce the logged V1 numbers exactly, which validates the replica.

| Design | Harness | Fmax per seed (MHz) | Median | LUT4 | DFF | LUT-RAM | BSRAM | DSP |
|---|---|---|---|---:|---:|---:|---:|---:|
| V0 | V1 | 128.72 / 127.03 / 123.02 | 127.03 | 9,563 | 1,866 | 0 | 4 | 1 |
| V0 | V2 | 97.20 / 100.66 / 111.21 | 100.66 | 9,723 | 1,437 | 0 | 4 | 1 |
| Opus 5.5 final | V1 | 302.21 / 278.71 / 315.76 | 302.21 | 3,128 | 1,491 | 36 | 4 | 1 |
| Opus 5.5 final | V2 | failed / failed / failed | - | 75,830 | 37,475 | 5,220 | 0 | 1 |

- V0 under V2: 429 fewer DFF (RVFI-only registers pruned), 160 more LUT4 (stall handling now kept), median Fmax -21%. On seed 2 the critical path runs from MEM/WB through forwarding into the ALU, not through the stall generator, so the drop is not attributed to one cause; the noise calibration has to separate it from placement variation.
- Opus 5.5 final under V2: the stall-only structures (4,096-entry instruction replay store, load cache, store buffer) are now synthesized. The design needs 75,830 LUT4 on a 20,736-LUT4 device and fails placement on every seed. Under V1 the same RTL reported 3,128 LUT4. Under a scoring rule in which cycles and timing describe the same circuit, V1's record design (983.24) would be a placement failure.

### Arithmetic and trace coverage: random trace programs (measured)
- `bench/programs/gen_random_trace.py`, seeds 1 to 3, committed as `random{1,2,3}.S`, built by `make bench`. Each starts with every M-extension op on every pair of 10 edge values, then random blocks (ALU, M ops, aligned loads/stores in a 64-byte window, forward branches and jumps, jalr, short counted loops). 9,982 to 11,003 retired instructions each before the edge matrix was added.
- V0 and the Opus 5.5 final design pass all three, with and without stalls.
- Planted bugs in V0:

| Bug | selftest | CoreMark CRCs | random (before edge matrix) | random (with edge matrix) |
|---|---|---|---|---|
| B1: DIVU by 0 returns 0 | pass | pass | fail | fail |
| B2: DIV INT_MIN / -1 returns 0 | pass | pass | pass | fail |
| B3: rs2 ignores MEM/WB forwarding | fail | fail | fail | fail |

  ALTOPS formal abstracts division, so under V1 gates B1 and B2 would have passed every check. Replaces the `test_alu.py` gate idea: module-level tests break on legitimate restructuring (agents rename and split the ALU), program-level traces do not.

### Provenance
- `tools/HARNESS_VERSION` (2.0.0-dev) in every results row; `env.json` records each tool's version and SHA-256 and a combined `toolchain_digest` (current: fe10e94c...).

## 2026-09-27: perturbation scoring in the harness (measured)

tools/eval/fpga.py now scores Fmax as the median over PERTURBATIONS, a list
of (k, seed) pairs: k=0 is the netlist `make` built, k>0 re-synthesizes with
the unused module zz_calib_pad (k assigns) read through SYNTH_PAD in
synth.tcl. The list stays at [(0,1),(0,2),(0,3)] (the V1 scheme) until the
calibration sets it.

Equivalence check (V0, harness path vs calibration driver, whose pad file
sat in the RTL dir instead of generated/var<k>/): k=0 seed 1 97.20 MHz,
LUT4 9723 in both; k=9 seed 1 136.71 MHz, LUT4 9705 in both. The pad file's
location does not matter, so the calibration's numbers apply to the
harness as-is (n=2 pairs, exact match).

Interim (2 of 7 designs complete, not a result): SD of ln(Fmax) across
variants 0.16-0.21 vs 0.04-0.07 across seeds within a variant.

## 2026-09-27: synthesis targets the wrong family; flow experiment

fpga/scripts/synth.tcl calls synth_gowin without -family, so Yosys maps for
its default gw1n while nextpnr places on GW2A-18C. The fabric is LUT4 in both
and the design places, but it is not the intended flow. This holds for all V1
results too.

The placement-noise calibration was stopped at 235 rows (V0, gpt-5_6-sol_rep1,
gpt-5_6-terra_rep3, gpt-6-astra_max_rep1 complete; astra rep2 partial): its
numbers describe gw1n synthesis and will be re-measured on the corrected
flow. Kept as the record of the V1-flow noise.

gpt-5_6-terra_rep3 k=9 (measured): LUT4 7830 vs 7782 unpadded, seeds 1-3 at
65.49 / 62.98 / 66.28 MHz vs 125.72 / 141.64 / 145.77. The neutral padding
changes the mapped netlist, not only placement.

EXP-2026-09-27-v2-synth-flow (pre-registered) compares -family gw2a, with
-noabc9, and with -retime on 3 designs x 9 variants x 2 seeds.

## 2026-09-28: run host; platform changes the netlist (measured)

V2 runs move to a Hetzner EX63 (20 cores, Ubuntu 26.04), set up by
research/v2/scripts/setup_server.sh with the same pinned versions as the Mac
(oss-cad-suite 2026-04-24, Yosys 0.64+149 2dc69a757, nextpnr-0.10-45,
Verilator 5.047, gcc 15.2.0-1, Python 3.13.12, cocotb 2.0.1, Claude Code
2.1.283, Codex 0.156.1).

Same inputs, same versions, different host (wrapper_compare.sh, seeds 1-3):

| design | Mac LUT4, MHz | Linux LUT4, MHz |
|---|---|---|
| V0 k=0 | 9723: 97.20 / 100.66 / 111.21 | 9699: 131.60 / 142.86 / 147.17 |
| terra k=9 | 7830: 65.49 / 62.98 / 66.28 | 7661: 123.84 / 150.72 / 147.08 |

The host is one more neutral perturbation. Every V2 number (calibration,
loop, final scores) must come from the run host; Mac numbers are pilots.
The run host is deterministic: V0 k=0 seed 1 rerun in another directory gave a
byte-identical synth.json and 131.60 MHz (n=1 repeat).

Synth flow decision: -family gw2a (research/runs/EXP-2026-09-27-v2-synth-flow/notes.md).
Pad module redefined as k unused wires (valid for k > 32). Calibration re-run on
the host: EXP-2026-09-28-v2-noise-server.

## 2026-09-28: nextpnr's Gowin timing misses deep arithmetic (measured)

Prompted by testing the vendor flow (Gowin EDA 1.9.11.03 Education, Linux,
headless gw_sh; research/v2/scripts/gowin_build.sh). V0 under Gowin: 5.14 MHz,
critical path 150 logic levels through the single-cycle 32-bit divider in
alu.sv (`a / b`, `a % b`). nextpnr reports 124-147 MHz for the same RTL.

Controlled test (research/v2/timing_check/{add,div}.sv): register -> one 32-bit
operation -> register, result fed back into the input LFSR so nothing can be
optimized away. Same part, one seed / default placement each:

| design | Yosys+nextpnr | Gowin EDA |
|---|---|---|
| add | 370.64 MHz, 79 LUT4 | 302.85 MHz, 6 levels, 77 logic |
| div | 122.64 MHz, 2140 LUT4 | 6.91 MHz, 133 levels, 2223 logic |

Both flows keep the divider (similar area). A combinational 32/32 divider
chains 32 subtract-and-select stages; ~7 MHz is physically plausible, 122 MHz
is not. nextpnr's own worst path for the divider was ~49 cells, i.e. about one
carry chain: it apparently does not time through from one ALU chain into the
next, so deep arithmetic is nearly free under the V1 metric.

Consequences (inferred): V1 Fmax understated the cost of deep combinational
arithmetic (V0 itself relies on it); agents could gain score by moving logic
into carry chains; part of the "synthesis chaos" may be which paths the timer
happens to see. Scope: n=1 build per cell; the 18x gap is not a noise effect,
but the exact missing arc in nextpnr is not identified.

## 2026-09-28: Opus 5.5 V1 winner under both flows (measured)

claude-opus-5_5_xhigh rep1 final (V1 score 983.24, +248%), RTL from repo.bundle.
One build per cell (nextpnr: seeds 1-3; Gowin: default placement).

| wrapper | Yosys+nextpnr | Gowin EDA |
|---|---|---|
| V1 (ready tied high) | 240.73 / 223.11 / 247.46 MHz, 3119 LUT4, 36 RAM16SDP4 | 48.92 MHz, 13 levels, 2872 logic, 1257 regs |
| V2 (stalls in hardware) | does not fit: 75,857 LUT4, 37,475 DFF | does not fit: 18,380 DFF > 15,750 |

Gowin's critical path: register file (cpu/u_rf/regs_regs...) -> dmem BSRAM,
13 levels. nextpnr claims ~4.2 ns for the same design; 13 LUT levels plus
routing cannot close in 4 ns on this part, so nextpnr is also missing arcs
outside carry chains, likely through LUT-RAM (RAM16SDP4) reads (inferred,
not isolated). V1's largest gain was scored on logic the timer did not see,
and the design only fit because the V1 wrapper let the stall logic be pruned.

## 2026-09-29: formal evals run one at a time host-wide (measured, 2.8.0 campaign)

The harness's formal gate still takes V1's machine-wide lock
(`/tmp/auto-arch-tournament.formal.lock`, `tools/tournament.py` `phase_gate`;
`AAT_MACHINE_LOCK_DIR` is unset under the runner). So at most one harness formal
eval runs on the host at a time, across all three runs; the cap of three
concurrent harness evals (`HARNESS_EVAL_SLOTS=3`, amendment 03) binds only the
Gowin builds. Seen at 16:17Z: Opus r14s1 and r14s2 (agents done 15:57Z) waited
with no child process, their orchestrator thread in `flock`, while Luna r12s1's
formal eval spent 21+ minutes on `reg_ch0`.

Effect on results: none found. The 45-minute formal ceiling starts inside
`eval_slot`, after the lock is held, so waiting never counts toward a timeout;
agents' budgets end before their slot's eval starts; formal verdicts do not
depend on when they run. Effect on wall time: a slow formal in one run delays
the other runs' rounds (cross-run coupling in time only), and one formal at -j6
leaves cores idle. Kept for the whole campaign (all 18 runs under 2.8.0).
Candidate for 2.9: `AAT_MACHINE_LOCK_DIR=off` under the runner, since
`eval_slot` already caps harness evals host-wide; then three formal evals at -j6
can overlap, so the timeout headroom must be re-measured before the change.

Cost seen in the 2.8.2 campaign (amendment 11, two runners): Opus rep2's champion
line needed 35 to 45 min per formal eval from round 10 on (four timeouts at the
2700 s ceiling: r11s1, r11s2, r15s1 on `pc_fwd_ch0`/`insn_add_ch0`), and GPT-6.1
Sol's round-10 slot 2 held the lock on `pc_fwd_ch0` from about 05:58Z Sep 30 until
its 2700 s timeout (about 06:44Z).
In those windows the host sat at load 1 with every other run's slots queued in
`flock` and no agent running. The Opus/Luna rep2 batch took 9.2 h against 6.6
to 7.8 h for rep1. Same verdict as above: wall time only, fixed for this campaign.

Prompt vs gate wording (2.8.2 campaign, GPT-6.1 Sol rep1 r14s1, Sep 30 ~11:35Z): the
implementation prompt forbids helper scripts "outside cores/{target}/" and asks for
scratch under $TMPDIR or ./.tmp, while the sandbox gate accepts only
cores/{target}/rtl/ and cores/{target}/test/test_*.py changes. An agent that wrote
self-check logs to cores/bench/*-local.log and hit its 30 min budget before deleting
them got `sandbox_violation` (slot broken). Identical rules for all systems, so the
campaign keeps them; for V3, state the gate's allowed set verbatim in the prompt.

Shared formal work dirs within a run (2.8.2 campaign, Opus rep4 r6s1, Sep 30 ~15:02Z):
every worktree's `formal/riscv-formal` is a symlink to the clone's one checkout, and
`riscv-formal/cores/` carries no sticky bit while the agent account has rwx through a
default ACL. Each `run_all.sh` call writes its own `cores/bench-w<random>/`, and the
harness's own formal evals of this run's slots land in the same directory, so an
agent can delete a sibling slot's or a harness eval's work dir. Not observed: an
audit of every agent `rm` of a `riscv-formal/cores/` path (all finished and live
runs, 28 commands) found no globs, the r6s1 deletion targeted its own run
(`bench-wkUFnqir6`, created by its own `run_all.sh` at 15:00:43Z), and no harness
`formal_failed` so far is a missing-file error. Reach is one run (one model's
slots); other runs' clones are not writable by that account. Kept for this
campaign; for V3, `chmod +t` on `riscv-formal/cores/` (only a dir's owner or the
operator may delete it) or a private checkout for the harness's formal evals.

## 2026-09-30: a cosim eval filled host memory (measured, 2.8.2 campaign)

At 15:55Z the harness's cosim of Luna rep4 slot r7s1 (operator uid,
`tools/eval/cosim.py`) ran its trace ELFs x 2 stall modes at once through a
thread pool; four `test/cosim/run_cosim.py` processes each held 11 to 17 GB
after 33 s and 30 to 34 GB after 80 s. RAM (64 GB) filled and swap reached
31.6 of 32.7 GB. The kernel OOM killer took one of them (PID 41168, 32.3 GB
anon RSS) at 15:57:23Z; the others ended at the 120 s per-ELF timeout by
15:57:52Z, and free memory was back to 61 GB. Nothing else was killed: the
three orchestrators and every live agent (GPT-6.1 Sol's r5 agents, then 9 min
old) carried on. The Claude Code babysit shell was reaped for memory pressure
(a monitoring loss, not a run effect).

Cause: `run_cosim.py` (a contract file) captures the simulator's whole stdout
and parses every RVFI line into a Python dict, up to 50 M cycles; a design
that never reaches `ebreak` emits tens of millions of retire records, and the
Python reference keeps up to 10 M more. The same thing happened once before,
agent side: Sep 29 12:54:48Z (2.8.0 campaign) the OOM killer took an agent's
own `python3` (uid 1003, hweagents-hwebench3 scope, 31 GB), not recorded at
the time. No memory limit exists on either side (`hweagents.slice`
MemoryMax=infinity; operator evals run unconfined).

Effect on results: the killed process belongs to the eval of the slot that
caused it, which fails cosim either way (no `ebreak` within the limits). The
OOM killer picks by size, so a well-behaved eval or agent (well under 1 GB)
is not the victim while a runaway is alive; the cost to other runs is about
two minutes of heavy swapping (wall time; agent budgets and the 45 min formal
ceiling are wall-clock). Kept for this campaign (contract file, no harness
edits mid-campaign). For V3: stream-parse the trace (or cap trace ELFs far
below 50 M cycles), bound concurrent trace processes, and give harness evals
and `hweagents.slice` a MemoryMax so one runaway cannot push the host into
swap.

## 2026-10-01/02: two more memory events (measured, 2.8.2 campaign)

Both on Sonnet 5.5 runs; details in the EXP-2026-09-28-v2-main monitor_review rows.

- 21:16Z to 22:01Z: the harness's own formal eval of Sonnet rep2 r8s2 (bench,
  `make -j6`) grew to 59.7 GB in its six heavy checks (causal, liveness, ill,
  pc_fwd, pc_bwd and one more) while every agent waited for the formal lock.
  Swap filled; at 21:59:28Z the kernel killed bench's user `dbus-daemon` first
  (systemd user services run at oom_score_adj 200, which outranks any solver)
  and then one solver (10.5 GB). The 45 min ceiling ended the eval at 22:01Z
  (`formal_failed: timeout`, the outcome it was heading for anyway). Runners,
  tmux, the monitor and the launcher run at oom_score_adj 0 in session scopes
  and survived; dbus is socket-activated and came back. The same design family
  had peaked at 59.6 GB at r4s2 (17:50Z) without a kill. Formal evals have no
  memory bound either: for V3, add one to the eval scope or size `-j` to memory.
- 03:38Z to 03:40Z: implementation agent r5s2 of Sonnet rep3 ran
  `python3 -m tools.eval.cosim . bench` in the background; one process reached
  61 GB in about 90 s (the 09-30 cosim mechanism, agent side), available memory
  fell to 0.6 GB, and it ended when the agent's Bash command returned (Claude's
  per-command PID namespace teardown), before any kill.
- Agent-side formal bursts (all three slots of a Sonnet round at `-j20` each)
  reached 39 GB resident at 18:59Z with no kill.

Count so far in the 2.8.2 campaign: two kernel OOM events (09-30 15:57Z cosim
eval, 10-01 21:59Z formal eval) and one near miss (10-02 03:39Z agent cosim);
none changed a scored outcome. The per-account MemoryMax amendment is pending
the operator's decision; it would bound the agent-side cases only.

## 2026-10-02: hypothesis YAML copy-back fails on an agent-owned file (2.8.2 campaign)

Sonnet 5.5 rep3 r12s0 broke as `hypothesis_gen_failed: [Errno 1] Operation not
permitted` on the main clone's `experiments/hypotheses/<id>.yaml`. The agent wrote its
YAML in its hypgen workspace (correct) and then also copied it into the main clone by
absolute path, which the hypothesis allow list permits. The harness copies the workspace
YAML out with `shutil.copy2`; copy2 writes the data (the ACL allows it) and then runs
copystat, whose utime/chmod need ownership, so it raises EPERM on a file the agent
account owns. First occurrence in all runs. V3 fix: `shutil.copyfile` for the copy-back,
or reject a main-clone hypothesis write up front with an explicit error.

## 2026-10-03: a slot deleted a sibling's live formal work dir (2.8.2 campaign, GPT-5.5 rep1)

The shared-work-dir risk noted on 2026-09-30 ("Shared formal work dirs within a run",
not observed then) happened once. GPT-5.5 rep1 implementation agent r4s0, tidying up
before it finished (~07:20 CEST), said "The only stray files are formal work
directories created by the formal script under the shared `riscv-formal` checkout"
and ran `rm -r` on three exact `formal/riscv-formal/cores/bench-w*` dirs: its own
(bench-wo0JMvTYY), r4s2's (bench-we4OufSiY, whose run had already ended with exit 0)
and r4s1's (bench-wQIcW2vpF, live). r4s1's self-check then failed with
`FileNotFoundError: 'reg_ch0/PASS'` after reaching `Status: passed`, and its agent
reran formal with fewer jobs ("the generated work directory disappeared"). No glob,
no malice: the agent took every `bench-w*` dir it saw as its own leftovers (they
show up as untracked content of the riscv-formal checkout in each worktree's view).

Reach: one run (one model's slots, one account). The harness's formal evals now run
in the clone's `.tmp/riscv-formal-eval` (each worktree's `formal/riscv-formal` link
is switched there for the eval; owned by the operator), so no eval or score was
touched; the cost is sibling self-check time inside the same system's run. Kept for
the campaign (a permission change now would give the remaining runs a different
setup); V3: per-slot work dirs (a `WORK_DIR` under the slot's TMPDIR) or `chmod +t`
on `riscv-formal/cores/`, and say in the prompt that `formal/riscv-formal/cores/` is
shared.

## 2026-10-03: two formal-eval OOM kills in one Sonnet round (measured, 2.8.2 campaign)

Sonnet 5.5 rep6 round 12; monitor_review rows 06:49Z, 06:52Z and 07:53Z. The
harness's formal evals of r12s2 (06:06Z to 06:51Z) and then r12s1 (06:55Z to
07:40Z) each grew to about 60 GB in six heavy checks at `make -j6`, the 10-01
21:59Z pattern. Each time the kernel OOM killer took exactly one solver
(06:48:56Z and 07:37:04Z, bitwuzla at 10.6 GB each) and nothing else, and each
eval then hit the 2700 s ceiling (`formal_failed: timeout`, which it was heading
for anyway). The other runs' agents had all finished and were waiting in the
formal lock queue, so the cost to them was queue wait (about 1.5 h of formal
lock held by two evals that both timed out), not swapping. The Claude Code
babysit shells were reaped once (a monitoring loss).

Count in the 2.8.2 campaign now: four kernel OOM events (09-30 cosim eval, 10-01
formal eval, 10-03 two formal evals) and one near miss; none changed a scored
outcome. For V3 the fix that covers these is a memory bound on the harness eval
itself (a MemoryMax on the eval scope, or `-j` sized to memory, with an OOM in
the eval mapped to `formal_failed`); the pending per-account agent cap does not
reach evals run as bench. Shorter formal ceilings for designs whose solvers pass
some memory mark would also give the lock back sooner.

Addendum (08:35Z): a second system did it. Sonnet 5.5 rep6 r15s1 ran `rm -rf
formal/riscv-formal/cores/bench-w*` and removed sibling r15s2's live work dir
(r15s2 re-ran its self-check and passed); the same wildcard appears once in that
run's round 12. Harness evals stay out of reach (`.tmp/riscv-formal-eval` is
bench-only), so this costs sibling agents time, not scores. The V3 fix above
(per-slot formal work dir, or a sticky `cores/` plus a prompt note) now covers
two systems.

## 2026-10-04: open-source reference cores, measured

`research/v2/reference_cores/` scores 10 configurations of 8 open-source
RV32IM cores the way the bench scores an agent's core. Stage 1 runs the
harness's own Gowin flow (read-only import). Stage 2 runs the bench's own
CoreMark and held-out ELFs in a Verilator testbench that copies
`test/cosim/main.cpp` (same stall model, seed, markers and scoring). The
cores are VexRiscv (MaxPerf, NoCache), VexiiRiscv, Ibex (small, maxperf),
Hazard3, ultraembedded riscv, biRISC-V, NEORV32 and PicoRV32. Best is VexRiscv
MaxPerf, at 228.0 CoreMark and 6,216 held-out. It scores above 21 of the 32
finished agent runs on CoreMark; every Opus 5.5 final and five of six Sonnet
5.5 finals beat it. Seven of the ten score below every agent final, except
Hazard3, which beats two.

- The method agrees with two published figures: VexRiscv MaxPerf measures
  2.598 CoreMark/MHz (published 2.57) and NEORV32 0.940 (published 0.95).
  The other published figures run 20 to 70% above the measured ones (no
  stalls, other flags, or extra extensions).
- V3: the V1 `cores/{picorv32,ibex,neorv32,vexriscv}/core.yaml` citations are
  wrong for this bench. PicoRV32's 0.516 is DMIPS/MHz; Ibex's 0.904 is the
  RV32EC "micro" config, which cannot run the bench ELF; NEORV32's 0.95 needs
  C plus caches; VexRiscv's 2.30 is the no-cache config. Replace them with the
  measured stage 2 figures.
- V3: references read memory one cycle after the request, as their native
  buses require. Agent cores read combinationally (`test/cosim/main.cpp`), and
  in the FPGA bench their instruction data is a register (the LFSR), so
  instruction memory costs them no cycle and no logic delay. A V3 contract
  with a synchronous memory port would make agent and reference numbers
  directly comparable.
- Ibex mainline merged CHERIoT in 2026-08. The rows pin e4bcf749, the newest
  mainline commit with no CHERIoT RTL, to match the published configs.

## 2026-10-04: cosim runaway, ended by the operator before the OOM killer

Same class as the 2026-09-30 entry. At 02:26Z the harness's cosim of GPT-5.5
rep5 slot r2s1 (bench, `run_cosim.py`, trace ELFs x stall modes in parallel)
grew three processes to 25, 17 and 15 GB within 30 s. MemAvailable fell to
226 MB at 02:26:41Z. Two ended by themselves within 40 s; the third kept
growing at about 0.85 GB/s, reaching 57 GB at 02:27:38Z with 1.4 GB
available. The operator killed it (PID 90218, SIGKILL) at 02:27:50Z. That is
the outcome the kernel OOM killer would have given seconds later, with no
swap storm first. The slot was recorded `cosim_failed: random1.elf
[--istall --dstall]`, the verdict it gets either way, since the design never
reaches `ebreak` within the limits. No kernel OOM kill; memory back to 61 GB
by 02:27:52Z; the r2 agents of the other slots carried on. Third harness-cosim
runaway in 2.8.2 (2026-09-30 Luna, 2026-10-03 GPT-5.5 rep3 r13s1 and r14s1
filled RAM briefly without a kill, now this). The proposed per-account
MemoryMax on `hweagents-<acct>.slice` would not cover it: harness evals run as
bench. The V3 fix in the 2026-09-30 entry (stream-parse the trace, bound
concurrent trace processes, MemoryMax on harness evals) is the one that
applies.

## 2026-10-04: extended suite, 15 more Embench-IoT kernels (exploratory)

`research/v2/extended_bench/` runs every finished champion (35 runs) and every
reference core on the five held-out kernels plus the other 15 Embench-IoT
kernels at the vendored commit. The ports and build flags are
bench/holdout's. Champions are built with `test/cosim/build.sh`'s command and
`test/cosim/main.cpp`; the held-out cycle counts reproduce exactly (175 of
175).

- All 700 champion-kernel runs give correct results.
- On the new 15 the system order matches held-out exactly, with run-level
  Kendall tau 0.954. Opus vs Sol is 1.279 (held-out 1.320).
- Same verdicts, same gaps: Opus vs Sonnet and Sol vs Astra are not
  distinguishable, as on held-out.

Two V3 items:

- Opus 5.5 rep6's champion puts wrong-path fetch addresses below 0
  (0xFFFFFF20 to 0xFFFFFFF8) on `io_imemAddr` on 10 of the 15 new kernels.
  The cause is an aliased next-fetch predictor entry applied to a PC near 0.
  The results stay correct, but main.cpp flags them as out-of-range (CLAUDE.md
  invariant 6). Every V2 gate missed it. Formal has no fetch-bounds property,
  and the harness's programs never put that predictor state near address 0.
  Fix in the contract: a fetch-valid signal, or a formal assertion that
  `io_imemAddr` stays in range.
- The held-out geomean takes only validated kernels (`tools/eval/holdout.py`),
  so a failure can raise it. Under that rule Opus rep6's new-15 geomean is
  2309 instead of 1971. No scored result is affected (every scored run
  validates all five). Count a failed kernel as zero instead.

## 2026-10-04: campaign complete; final analysis and amendment 12 step 2

GPT-5.5 rep6 finished at 10:03Z, the last run of V2. All six systems have 6
scored runs (36 runs; the GPT-6 Sol pilot is the 37th, unscored). Final
analysis: `research/runs/EXP-2026-09-28-v2-main/analysis_final.md`.

- Primary: Opus 5.5 vs GPT-6.1 Sol 1.320 [1.183, 1.473], p = 0.0005, Opus
  ranks higher. Amendment 01: both pairs with Luna separate.
- Amendment 13, 12 pairs, Holm: 9 separate. The three that do not are Opus vs
  Sonnet 5.5, Sol vs Astra and GPT-5.5 vs Luna. So the result is three tiers:
  {Opus 5.5, Sonnet 5.5} > {GPT-6.1 Sol, GPT-6 Astra} > {GPT-5.5, Luna}, with
  rank intervals 1-2, 3-4 and 5-6. Every pair across tiers separates (Holm p
  at most 0.0076).
- The extended suite, rerun at 6 of 6 for every system, gives the same tiers
  on the 15 unseen kernels, with the same three pairs indistinguishable
  (run-level Kendall tau 0.956).
- Amendment 12 step 2: both class (b) champions pass all 53 checks with the
  formal-only branch replaced by the synthesized one (Opus rep2 with its
  512-entry fetch store, 372 s; Sonnet 5.5 rep5 with its RAM-slice register
  file, 1,378 s). No run is removed in the sensitivity repeat. The contract
  gap stays a V3 item (formal must see the scored RTL).

Operations over the campaign's last day: one harness cosim runaway ended by
the operator ahead of the OOM killer (02:27Z, GPT-5.5 rep5 r2s1). The guard
started after it never had to fire.

## 2026-10-04: amendment 15 (random control, textbook baseline, Artix-7)

The V1 paper's reviews (MLCAD 2026) asked for a control that separates the
agents' reasoning from the gates plus blind sampling, for baselines or
ablations, and for evidence beyond one FPGA. Amendment 15 (committed 18:45Z,
before any measurement) adds three things:

- Part A: the V1 random-mutation control (no LLM; 1 to 3 seeded single-line
  operator, ternary or constant edits per slot, lint-clean) rerun on harness
  2.8.3, 3 runs of N=15, K=3, after the ablation. V1 measured 0 of 135
  accepted (all failed formal).
- Part B: the textbook-edit baseline, V0 with its single-cycle divider replaced
  by a radix-2 iterative one (34 cycles in EX, pipeline stalls until done).
  RTL and unit tests in `research/v2/textbook_baseline/` (79 cocotb cases
  pass). One deviation from the amendment text: under ALTOPS the divider
  answers after one cycle, because riscv-formal's liveness check needs the next
  retirement within 10 cycles; the agents' dividers do the same. Harness evals
  (`research/v2/scripts/score_textbook.py`) run after the ablation.
- Part C: every final design synthesized for an AMD Artix-7 200T
  (xc7a200tsbg484-1) with Vivado 2026.1 on the operator's workstation,
  two-pass clock target, median Fmax over three placement directives; held-out
  scores recomputed from the FPGA-independent cycle counts. Flow in
  `research/v2/xfpga/`. It runs off the bench host, so it starts now.

## 2026-10-04: Artix-7 transfer (amendment 15 part C)

All 48 designs (36 finals, the Sol pilot, V0, 10 reference configurations)
built in Vivado 2026.1 for xc7a200tsbg484-1, no failures, 19:12Z to 20:39Z.
Analysis: `research/v2/xfpga/results/analysis.md` (exploratory).

- The bottom of the ranking transfers, the top does not. Every pair between
  {GPT-5.5, Luna} and the other four separates on both FPGAs (8 of 8). Among
  the top four, the four pairs that separated on Gowin (Opus vs Sol, the
  primary; Opus vs Astra; Sol vs Sonnet; Astra vs Sonnet) do not separate on
  Artix-7. Opus vs Sol: 1.320 [1.183, 1.473] on Gowin, 1.028 [0.813, 1.299]
  on Artix-7. Artix-7 order: Sonnet 7,511 > Opus 6,724 > Sol 6,543 > Astra
  6,236 > GPT-5.5 4,385 > Luna 4,245. Kendall tau-b over the six systems
  0.867; Spearman over the 36 runs 0.769.
- The agents' designs gain less from the faster fabric than the reference
  cores: Artix-7/Gowin Fmax 1.17 (0.80 to 1.51) vs 1.67 (1.33 to 1.94),
  Welch p = 1.4e-7. Opus transfers worst (0.96; four of six runs are slower
  on Artix-7, each limited by an EX-stage arithmetic or forwarding path with
  7.8 to 8.7 ns of logic delay). The dmem read does not explain it: the seven
  designs whose worst path runs through the bench's distributed-RAM dmem have
  a higher ratio (1.27) than the other 29 (1.14). On Artix-7, VexRiscv
  MaxPerf (10,246) and VexRiscv NoCache (8,772) score above every system's
  geometric mean; on Gowin, MaxPerf (6,216) sat between tiers 1 and 2.
- Reading: fifteen rounds of tuning against one vendor's timing report
  produce designs specialized to that part. The V2 ranking is a ranking on
  the Gowin contract; across FPGAs only the split between the top four and
  {GPT-5.5, Luna} holds.

## 2026-10-05 01:36Z: agent-side cosim runaway, operator kill (amendment 14 ablation)

An implementation agent of ablation rep4 (hwebench2, round 3) ran the harness
cosim script on a probe build of its candidate (`test/cosim/run_cosim.py
.../micro_earlyfwd_probe/obj_dir/cosim_sim`). The process grew to 56 GB in
about 80 s, the class of the 09-30 eval runaway and the 10-02 agent near miss.
At 01:36:33Z the memory watch reported 3,988 MB available (swap 2.5 GB used);
the operator killed that one process at 01:36:47Z (SIGKILL), and available
memory returned to 57 GB. No kernel OOM kill happened, every runner and
orchestrator kept running, and the slot itself continued (the agent sees its
own probe command fail; a design that drives the trace to that size never
reaches `ebreak`, so it would have failed cosim anyway).

The operator's cosim guard only watched bench-owned processes. It now also
covers the agent accounts with the same rule (MemAvailable under 4 GB and a
`run_cosim.py` over 20 GB resident), so this class no longer depends on the
operator's reaction time. A per-account memory cap is still a V3 item (V3.md
item 6). Snapshot of the guard: `research/v2/scripts/ops/cosim_guard.sh`.

## 2026-10-05 05:35Z: provider capacity errors cost two ablation slots

Ablation rep6, round 10: hypothesis slots r10s0 and r10s2 broke as
`hypothesis_gen_failed`. Both agent logs hold only `"Selected model is at
capacity. Please try a different model."` on the first attempt and on the
harness's one retry, so no agent ran. The third slot (r10s1) ran normally,
and round 11's three agents started normally a few minutes later.

The same Codex error appears in the agent logs of five scored campaign runs
(GPT-6.1 Sol reps 2, 4 and 5, GPT-6 Astra reps 2 and 3) and of ablation rep3,
but there the retry always succeeded, so this is the first time it cost slots.
Treatment, as for every slot-level failure in V2: the slots count as broken
and the run continues. The incident policy's re-run applies to a run stopped
by a harness, host or provider failure, and amendment 01's quota rule to quota
pauses; neither happened. The two slots are listed with the ablation's
descriptive results.

## 2026-10-05: amendment 14 result, lessons make no measurable difference for GPT-6.1 Sol

The last ablation run (rep4) finished at 10:29Z; all six no-lessons runs are
scored and passed the per-run checks (harness 2.8.3, fixture fad7d02, clean
runner, probe confined, five held-out kernels validated, no LESSONS.md in any
bundle's history, no `lesson` field, no scribe run, no secrets). Analysis:
`research/runs/EXP-2026-09-28-v2-main/analysis_ablation.md`
(`research/v2/scripts/analyze_ablation.py`).

- Pre-registered test, held-out score, full / no lessons: 1.021, 95% CI
  [0.913, 1.140], bootstrap [0.942, 1.114], p = 0.68. Verdict: not
  distinguishable at n=6. The CI rules out a gain from the lessons larger
  than about 14%.
- Geometric means 5,320 (full) and 5,213 (no lessons); CoreMark 215.1 and
  212.5. Without lessons the runs spread twice as wide (SD of ln held-out
  0.104 vs 0.048): they hold both the lowest Sol run (rep1, 4,374) and the
  highest (rep6, 5,875).
- Slots: 54 / 208 / 7 (full) and 52 / 215 / 3 (no lessons) accepted /
  rejected / broken. Two of the three no-lessons breaks are the rep6
  capacity errors; one is a formal timeout.
- Wall time 9.9 h vs 13.3 h per run, mostly the skipped scribe step and the
  different host load. Tokens are about equal (135M vs 138M in per run).
- Not matched (amendment 14 `not_matched`): different dates, harness 2.8.3
  vs 2.8.2 (no behavior change outside the scribe), three runs at once.

## 2026-10-05: the random-mutation control drew one mutation set per run, in V1 too (amendment 16)

Smoke20 (amendment 15 part A, harness 2.8.3) finished done with three
formal_failed slots, and the agent log said "applied 3 mutation(s), draw 1"
for every slot. An offline replay of `tools/agents/random_agent.py`
explained it:

- The implementation prompt has the hypothesis title and text but not its
  id. The agent's id parser returns nothing and every slot seeds with
  `<seed>:no-id`. Nothing is ever accepted, so every slot starts from the
  same RTL and applies the same edit.
- Under V2's agent accounts the runner's seed (`RANDOM_AGENT_SEED`, 100 +
  rep) is dropped by the environment allowlist, so the seed is 0 in every
  run. Replaying `0:no-id` on V0 reproduces the smoke exactly: register
  reads of x1..x31 return zero (`reg_file.sv:50` `==` to `!=`), an ALTOPS
  DIVU formula and a decoder bit. 46 of 53 formal checks fail.
- V1's control (EXP-2026-07-e1b-random-control) had the first defect but
  not the second. Each V1 rep applied one mutation set in all 45 slots:
  "0 of 135" is three distinct mutation sets, each repeated 45 times. The
  three sets, replayed on V1's fixture (6f898db) with today's Verilator:
  rep1 decoder mem_width, an ex_stage forward select and the SRLI decode;
  rep2 the ALTOPS REMU constant and pc + 5; rep3 the SLLI decode and
  is_illegal set on a legal path.

Harness 2.8.4 (fixture bench-v2.8.4 = tag hwe-bench-v2.8.4) fixes both:
the agent takes the id from its worktree's name (the orchestrator names
each worktree after the hypothesis id), the seed passes to the agent
account, and the agent prints its mutation record to the archived agent
log (the orchestrator keeps implementation_notes.md only for slots that
reach the FPGA eval, so the records of broken slots were lost). No LLM
run is affected. Part A runs on 2.8.4 after smoke21.

V3 item: a control's behavior needs a check of its own, not only its
outcome. Here the outcome (everything fails formal) was the predicted
one, which is why V1 never noticed that the 135 slots were 3 draws.
