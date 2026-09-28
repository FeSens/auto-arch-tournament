# HWE Bench V2: what to write about

Working notes for the V2 paper. Each item says what we found, how sure we
are, and where the evidence lives. Status labels: **measured** (an artifact
on disk backs it), **inferred** (plausible reading of measured data, not
isolated), **pending** (the run that answers it has not happened).
Detailed record: `research/v2/NOTES.md` (append-only).

## 1. The headline correction to V1: the timer was wrong

**Finding (measured).** nextpnr-himbaechel's timing model for the Gowin
GW2A-18 misses whole classes of paths. The same RTL, timed by the vendor's
own tool (Gowin EDA 1.9.11.03):

| design | Yosys + nextpnr | Gowin EDA |
|---|---|---|
| reg -> 32-bit add -> reg | 370.6 MHz | 302.8 MHz |
| reg -> 32-bit divide -> reg | 122.6 MHz | 6.9 MHz (133 logic levels) |
| V0 (single-cycle divider in the ALU) | 124-147 MHz | 5.14 MHz (150 levels) |
| Opus 5.5 V1 winner, V1 wrapper | 223-247 MHz | 48.9 MHz (13 levels) |

- Adders agree roughly; the divider differs 18x with the same area in both
  flows. nextpnr's own worst path for the divider is about one carry chain.
- The Opus design's worst path under Gowin (register file in LUT-RAM ->
  data memory, 13 levels) cannot close in the ~4.2 ns nextpnr reports.
- **Inferred:** nextpnr does not time from one ALU carry chain into the next,
  and probably not through LUT-RAM reads. Exact missing arcs not isolated.
- **Consequence for V1:** deep arithmetic and LUT-RAM paths were nearly free,
  V0 itself relied on that, and V1 rankings change under the vendor timer
  (e.g. gpt-5_6-sol rep1: 180.7 MHz nextpnr median, 5.4 MHz Gowin).
- Evidence: `research/v2/NOTES.md` (2026-09-28 entries),
  `research/v2/timing_check/{add,div}.sv`, `research/v2/scripts/gowin_build.sh`.
- Paper angle: a benchmark is only as good as its thermometer; the V1 paper
  needs an erratum. This is also a general warning for open-source FPGA
  flows used as reward signals.

## 2. V1's second hole: stall logic was free (measured, V1 paper already hints)

- The simulator stalled memory (~22%) but the FPGA wrapper tied the ready
  signals high, so logic that only handles stalls was pruned from the timed
  netlist. Stall-free recount on 7 recoverable designs: Opus gain 247.7% ->
  169.9%, others barely changed.
- Stronger now: the Opus V1 winner does not fit the chip at all once stalls
  are real (nextpnr 75,857 LUT4; Gowin 18,380 FFs > 15,750). It fit in V1
  only because the stall handling was optimized away.
- V2 fix: `fpga/bench_stall_gen.sv` drives the ready signals in the timed
  netlist with the same xorshift sequence the simulator uses (equivalence
  test: 100k cycles, `tools/eval/test_bench_stall_gen.py`).

## 3. Synthesis chaos in the open flow (measured), and why it disappears

- Circuit-neutral changes (an unused padding module) moved nextpnr Fmax far
  more than placement seeds did: SD of ln(Fmax) across variants 0.22 pooled
  vs 0.05 across seeds; one design 63 vs 140 MHz from padding alone (the
  mapped netlist itself changed: 7,830 vs 7,782 LUT4).
- Same inputs on a different host (Mac vs Linux, same tool versions) gave
  different netlists and Fmax (V0 9,723 vs 9,699 LUT4; 97-111 vs 132-147 MHz).
- Under the open flow, the acceptance margin needed to keep false accepts at
  5% would have been 42% (pre-registered rule, 7 designs,
  `research/runs/EXP-2026-09-28-v2-noise-server/notes.md`). The loop could not
  have rewarded realistic gains.
- Synthesis options did not fix it: `-family gw2a` (a real bug: V1 synthesized
  for gw1n), `-noabc9` (does not fit), `-retime` (loses ~27% Fmax)
  (`research/runs/EXP-2026-09-27-v2-synth-flow/notes.md`).
- Gowin EDA ignores the same neutral changes entirely (0 variance on 4
  designs, unused modules and unused wires inside `core`), is bit-reproducible
  run to run, and its only free variable (placement algorithm) moves Fmax by
  ~2.7% (pooled SD). Margin under Gowin: 4.6%
  (`research/runs/EXP-2026-09-28-v2-gowin-{pilot,calibration}/notes.md`).
- Caveat to state: the neutral probes are pruned early in Gowin; they show
  Gowin lacks nextpnr's name/order chaos, not how much a small functional edit
  moves Fmax (that is a real property of the new design).

## 4. Correctness gates were too weak (measured)

- V1's cosim ran selftest (115 instructions) and CoreMark only; two planted
  divider bugs (div-by-zero, overflow) and a forwarding bug passed V1's gates.
- V2 adds three generated random trace programs (edge-value M-op matrix,
  loads/stores, branches, loops), each run with and without stalls. The gate
  sanity test (`tools/eval/test_gate_sanity.py`) shows V0 passes and all three
  planted bugs are rejected, on the Mac and on the Linux run host.

## 5. Methodology changes (what V2 is)

- Metric: held-out score (5 kernels the agents never see) x vendor Fmax,
  final champion re-measured. CoreMark stays the optimization signal.
- Acceptance: pre-registered margin (4.6%) instead of any-improvement.
- Statistics: 6 runs per system, interleaved (both systems' rep r start
  together, alternating launch order), Welch t-test + bootstrap on ln score,
  pre-committed "not distinguishable" wording. Pre-registration files are
  write-once (`research/runs/*/prereg.yaml`).
- Isolation: agent CLIs run as separate OS accounts (one per concurrent
  run) that cannot read the held-out kernels, results, or each other; same writable paths for both CLIs (V1:
  Codex could read anything, Claude could not). Found and fixed on Linux:
  Codex's sandbox blocked its own formal self-check (Claude's did not).
- Quota handling: provider limits pause and rerun the attempt from scratch;
  logged, never counted against the agent (V1 lost 23 slots to one limit).
- Provenance: harness version, toolchain digest (incl. Gowin binaries), CLI
  versions, agent account recorded per row. Pinned toolchain on one host.
- No Yosys/nextpnr in the loop: scoring, build gate, `make fpga`,
  `make timing`, prompts and logged critical paths are Gowin's; the agent
  account cannot run nextpnr. Yosys remains only inside riscv-formal.

## 5b. Leak audit (measured; details in `research/v2/LEAKS.md`)

- Found before any scored run, after the campaign monitor showed a Codex
  agent searching `cores/v1` for past divider work. 12 channels; the main
  ones:
  - V1's winners were in every clone: `cores/v1` (champion RTL, 60+ logged
    hypotheses) and README's table of V1's 10 accepted winners in merge
    order. V1 kept them on purpose ("read-only reference") and the prompts
    pointed agents at them.
  - Concurrent runs shared one OS account: any agent could read the other
    live runs' clones, and Codex could read every Claude transcript in the
    shared home.
  - `ps` showed other runs' command lines; files in `/tmp` were
    world-readable; Codex's default web search mode could reach the
    benchmark's published results.
- Fixes (harness 2.1.0): the clone is an allowlist (target core + eval
  contract); one OS account per concurrent run, a fresh HOME per run, a
  wipe between runs; `/proc` hidepid; umask 007; Codex web search off.
- Paper angle: running agents concurrently on one host is a shared-machine
  security problem; a denylist chosen for convenience in V1 handed every
  agent the previous generation's ideas. Allowlist + separate OS principals
  + a live transcript monitor.

## 6. Engineering lessons worth a short section or appendix

- Same tool versions are not the same tool: host OS/libc changes netlists.
  Freeze one run host.
- Ubuntu 26.04 specifics that silently break a harness: Rust coreutils
  (`tail -5 a b` rejected), glibc 2.43 refusing executable-stack libraries
  (uv's libpython -> every cocotb test failed), Python 3.14 vs cocotb 2.0.1.
- Ubuntu 26.04 restricts unprivileged user namespaces through AppArmor, and
  Claude Code's Bash sandbox needs one: every agent shell command failed
  ("apply-seccomp: write /proc/self/setgroups ... Permission denied") while
  Codex's sandbox worked. Found by the campaign monitor on the smoke run,
  before any scored run. Unnoticed, it would have handed the comparison to
  Codex.
- The harness executes from the fixture clone, so a benchmark run must pin a
  harness tag, not a branch.

## 7. Results (pending)

- Main comparison, Claude Opus 5.5 (xhigh, Claude Code) vs GPT-6 Sol (xhigh,
  Codex CLI), 6 + 6 runs, N=15, K=3: **pending**.
- Smoke test only (one round each, old timer, not a result): both systems ran
  end to end as the isolated account; held-out scoring and provenance worked.
- V2 smoke champions under Gowin: Opus 47.7 MHz, GPT 32.7 MHz; both replaced
  V0's single-cycle divider in round 1 (n=1 round each, not a comparison).

## 8. Limitations to state

- Gowin EDA Education edition: closed source, one version, one part; results
  are relative to that vendor's timer and placement.
- The placement-option median is effectively one value (options 1 and 2
  coincide), so the margin's independence assumption does not hold; the
  single-draw margin would be 6.5%.
- Power: the run-to-run spread under Gowin is unknown before the main runs;
  n=6 may end "not distinguishable".
- One benchmark workload (CoreMark) drives optimization; held-out kernels are
  five small programs.
