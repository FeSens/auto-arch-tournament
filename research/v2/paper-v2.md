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

- **V1 contamination, measured on V1's own transcripts:** 14 of 36 published
  V1 runs read `cores/v1` (V1's own champion RTL, hypothesis log and, in 5
  runs, its `LESSONS.md`), which the prompts called "read-only reference".
  The propensity is system-specific: gpt-5_4_xhigh and kimi-k2_6 3/3 runs,
  gpt-5_5 0/9, Opus 0/1. No V1 final design copied a V1-specific file
  verbatim; whether the reads moved V1 scores is not identified (n <= 3,
  correlational). So V1 partly measured "consults a prior solution" as well
  as "designs a CPU". Evidence: `research/v2/v1_contamination.txt`.

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
  - Codex loaded the ChatGPT account's connected apps into every agent
    session (201 tools, 90 of them GitHub, which reaches this benchmark's
    own repository). No agent called one, but the channel was open; it is
    on by default in the CLI version under test.
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

## 5c. Incident 01: the first campaign was stopped (measured)

- The V2.1 campaign ran 6 h (batch 1, rep 1 of each system, ~19 of 45 slots)
  and was stopped as a harness failure under the incident policy; its runs
  are reported, not scored (`research/runs/EXP-2026-09-28-v2-main/incident_01`).
- Cause 1, a CLI-specific harness artifact: Claude Code's bubblewrap sandbox
  leaves empty placeholder files (`.bashrc`, `.mcp.json`, `.vscode`, ...)
  where a command runs. Hypothesis agents share the clone root, so one
  agent's off-limits check saw another's live placeholders and rolled the
  slot back: 4 of 15 Opus hypothesis slots lost, Codex unaffected. Three
  smoke rounds had missed it (timing-dependent).
- Cause 2, cross-run interference: three runs x three slots, plus agents'
  self-checks, all ran formal at `make -j20` on 20 cores (load 20). Formal
  checks hit the 45-min ceiling because of what other runs were doing.
- Fixes (harness 2.2.0): placeholders ignored (and purged before every
  build, so they never reach the eval); a host-wide cap of three concurrent
  harness evals, formal at -j6, timeout counted from slot acquisition;
  agent CLIs at nice 10 so their self-checks yield to scoring.
- Found by the post-fix smoke: a third Claude-only artifact. Claude Code's
  sandbox writes a `.claude/` dir (0700, agent-owned) wherever it works,
  including `cores/bench/rtl/`; the runner's final step copied the whole
  rtl/ working tree, hit it, and lost the run at the finish line (no result
  row, no held-out score). Every Opus run of the campaign would have ended
  this way. Fix: save the git-tracked design only; a runner exception now
  leaves a rerunnable `harness_error` row instead of no trace.
- Incident 02 (harness 2.2.0 campaign, stopped after 1.5 h, not scored,
  `research/runs/EXP-2026-09-28-v2-main/incident_02`): hypothesis agents
  shared the clone root. An Opus hypothesis agent (r3s0) ran a trial
  experiment in place (edited `core_pkg.sv` and three other RTL files, ran
  a Gowin build, reverted with `git checkout`) and finished clean; a
  sibling (r3s2) finished during the trial, its before/after check saw the
  edits, rolled them back under the running experiment and failed the
  innocent sibling. The third sibling was reading `rtl/` meanwhile. Across
  the batch, 4 of ~12 Opus hypothesis agents ran trial experiments (3 on
  copies, 1 in place); 0 Codex hypothesis agents edited the tree. So the
  shared tree turned a compliant behavior into a lost slot for the system
  that experiments. Fix (harness 2.3): each hypothesis agent works in its
  own disposable worktree of the champion; its YAML is copied out; the
  main clone is still checked for absolute-path writes.
- Incident 03 (harness 2.3.0 campaign, stopped after 1.7 h, not scored,
  `research/runs/EXP-2026-09-28-v2-main/incident_03`): the K=3 agents of a
  run shared one riscv-formal checkout (their worktrees symlink it), and
  `formal/run_all.sh` named its work dir `<core>-$$` and reaped dirs whose
  PID failed `kill -0`. Both agent sandboxes (Claude Code and Codex) run
  shells in their own PID namespace, where `$$` is 2 or 3 for every agent
  and every outside PID looks dead. So siblings staged formal checks in one
  dir and deleted each other's live runs. The harness's own formal eval
  was never hit (it runs in a separate harness-only copy since a
  2026-09-26 fix), but agents lost time and got false formal results: all
  three systems reported it in their own words ("Another sandbox's formal
  run, sharing the same riscv-formal checkout, deleted my work directory
  mid-run", Opus; "staging directory disappeared before SBY wrote
  `reg_ch0/PASS`", Luna; Sol renamed its core to dodge the collision). The
  same reports are in smokes 3, 4, 5, 6 and 8 (up to 7 in one run),
  including the one that validated harness 2.3; the monitor missed them
  because it scanned commands, not what agents say. Fix (harness 2.4): unique work
  dirs (mktemp name, plain mkdir so permissions follow umask), a flock held
  for the run's lifetime, reaping only dirs whose lock is free and older
  than 10 minutes, the harness removing exactly its own pinned dir; a
  regression test runs two formal invocations in separate PID namespaces
  (fails on the old script). The monitor now raises HIGH on agent messages
  that report interference from outside their slot.
- Incident 04 (harness 2.4.0 campaign, stopped after 1.3 h, not scored,
  `research/runs/EXP-2026-09-28-v2-main/incident_04`): the three
  concurrent runs (one per system) shared the host's 20 cores per thread,
  the Linux default. A 10-minute sample (60 points) found one run's agents
  on 11.7 cores on average (peak 25.4) against 2.6 and 1.0 for the other
  two, with the machine oversubscribed in half the samples; whenever it
  was, the other runs' own self-checks slowed inside their fixed 30-minute
  budgets. The harness's scoring evals kept priority (nice 10 on agents)
  and no timeout had occurred, but a run's working conditions depended on
  how many threads another system's agents spawned. Fix (harness 2.5):
  each agent account runs its commands in its own cgroup slice with equal
  CPU weight, so contended runs get equal shares whatever their thread
  count; the agents' parent slice has weight 20 against the harness's 100,
  the ratio nice 10 gave. The first version was inert (systemd enables the
  cpu controller below a slice only if a child sets a weight; all agent
  threads still competed as one pool) and a measured check caught it:
  with 20, 20 and 2 spinning threads the 2-thread run got 1.0 core, what
  per-thread sharing gives; after the fix it gets 2.0 and the two
  20-thread runs split 8.9/9.1 on average over four trials. Live in the
  2.5 campaign (2026-09-29 00:00Z, load average 54): with 24 runnable
  solver threads in the Opus run and 21 in the Luna run, the two got 10.2
  and 9.7 cores over 15 s. The 2.5
  validation smoke then surfaced one more shared scratch space through the
  new monitor rule: the runner set one TMPDIR per run, the implementation
  prompt tells agents to stage scratch files there, and an Opus agent
  reported a sibling slot overwriting its logs. Each agent invocation now
  gets a private TMPDIR under its own worktree, removed when it exits.
  The next smoke surfaced a cross-run collision between the two Codex
  systems: Codex's sandbox treated the shared /tmp as writable, so it
  created /tmp/.codex and /tmp/.agents as bubblewrap mount targets and
  removed them afterwards, and when the Sol and Luna runs overlapped, one
  account's Codex could not remove the other's and failed the agent's
  command ("failed to remove synthetic bubblewrap mount target
  /tmp/.codex: Operation not permitted"; 4 times in the 2.4 campaign's
  first 1.3 h). It had been filed as a benign access denial. Codex now
  runs with /tmp excluded from its writable roots (verified: no mount
  targets appear, /tmp writes fail, TMPDIR writes work), matching Claude's
  sandbox, which never allowed /tmp.
- Incident 05 (harness 2.5.0 campaign, stopped after 3.3 h in rounds 6-7,
  not scored, `research/runs/EXP-2026-09-28-v2-main/incident_05`): two
  isolation gaps, neither of which changed a score.
  (1) Every V2 harness (2.0 to 2.5) handed the Claude login token
  (`CLAUDE_CODE_OAUTH_TOKEN`) to every agent, the two GPT systems' Codex
  agents included, as an argument of the `env` command that launches the
  agent. A probe with a dummy value showed that Codex 0.156.1 passes it on
  to the agent's shell commands (`printenv` finds it), so a GPT agent could
  have used Anthropic's models through it. No agent transcript, Codex
  session file or archive on the host contains the token (all searched), so
  none read it. The launch command also went into sudo's log and, as the
  systemd scope's description, into the journal (both root-only).
  (2) An Opus implementation agent started its formal self-check in the
  background (`( ... run_all.sh ... ) &`), polled it with `sleep`, and ended
  its session before it finished. Its solver processes had been reparented
  to init, so the harness's process-tree kill never saw them, and they ran
  on in the run's CPU slice for 30 minutes after the agent exited (16
  solvers at first), into time the run's next round would use. The journal
  shows 1 such case in 176 agent invocations (every other scope ended within
  0.8 s of its agent); the run was waiting on a harness eval, so no other
  slot shared the CPU with them.
  Fix (harness 2.6): an agent gets only its own provider's credential, in a
  file under its private TMPDIR that the launch wrapper sources and deletes,
  never on a command line. Each agent command runs in a scope of its own,
  and the root helper kills everything left in it (`cgroup.kill`) when the
  command exits or is killed. The agent accounts may not use cron or at,
  whose jobs would run outside every scope and into the account's next run.
  The runner refuses to start unless a detached test process dies with its
  command, and the monitor raises HIGH on an agent scope without its agent
  CLI. Live tests with a real agent account: a detached, signal-ignoring,
  reparented process dies with its command and on the harness's timeout
  path (both tests fail on the 2.5 helper).
- Paper angle: a comparison of agent CLIs needs per-CLI integration
  testing under the real concurrency, and a monitor that reads outcomes by
  class per system; the bias showed up as one system's "broken" count.

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
- Separate OS accounts expose harness assumptions that one account hid:
  POSIX ACLs give the operator access through the ACL mask, and any
  `chmod 0700` by the agent (Gowin does it to its XDG runtime dir) zeroes
  that mask. `shutil.rmtree(..., ignore_errors=True)` then silently left
  agent-built directories behind: in the V2.1 smoke it crashed a GPT-6 Sol
  run (the eval could not recreate its build dir), and the same silent
  failure in the pre-eval purge would have let agent-built artifacts reach
  the eval. Fix: every harness deletion retries as the run's account and
  raises if anything survives (`tools/eval/_subprocess.py:remove_path`).
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
