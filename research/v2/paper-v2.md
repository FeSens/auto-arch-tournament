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

## 4b. V1's random control was three draws, not 135 (measured)

- V1's random-mutation control (no LLM; 1 to 3 seeded single-line edits per slot, lint-clean)
  reported 0 of 135 slots accepted. The agent seeded each slot from the hypothesis id, and the
  implementation prompt does not contain the id, so every slot of a run drew the same edits.
  Nothing was accepted, so every slot started from the same RTL: each V1 run tested one
  mutation set 45 times. Replaying V1's three seeds on V1's fixture recovers the three sets.
- The expected outcome (everything fails formal) hid the defect. V2 found it in a smoke run:
  every slot's log reported the same draw, and an offline replay showed one edit set.
- V2 fix (harness 2.8.4, amendment 16): the id comes from the worktree name, the seed reaches
  the agent account, and every slot's mutation record goes into the archived agent log.
  135 slots now give 135 seed materials and 132 distinct edit sets (section 7).
- Evidence: `research/v2/NOTES.md` (2026-10-05, amendment 16),
  `research/runs/EXP-2026-09-28-v2-main/amendment_16.yaml`.

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

## 5a. Fixture, agent scope and security (V1 review items)

**V0 provenance.** V0 is the same RTL as V1's (no diff in `cores/bench/rtl` between V1's fixture
6f898db and tag hwe-bench-v2.8.4). An LLM agent wrote it from a human-written specification
(`docs/bootstrap-prompt.md`). It passed the full gate stack and was frozen at a git tag before
any benchmark run. It is a 5-stage in-order RV32IM core with no branch prediction and no
caches. Its single-cycle divider limits it to 5.4 MHz under Gowin, which leaves the headroom
the benchmark measures. The ten reference cores and the textbook edit place it on an
external scale.

**What each agent sees and may do** (harness 2.8.4, `tools/agents/`):

| | Hypothesis agent | Implementation agent | Scribe |
|---|---|---|---|
| Prompt | full champion RTL, architecture and contract docs, `core.yaml` with the current Fmax, LUT4 and CoreMark, current and V0 fitness, the 4.6% margin, the last 5 slot outcomes (title, outcome, change, Fmax, worst path), the lessons file | the hypothesis, the docs, the full champion RTL; no metrics, history or lessons | one finished slot: its hypothesis, outcome, fitness, notes and RTL diff (8,000 characters) |
| May write | its hypothesis file only; edits in its scratch worktree are discarded | `cores/bench/rtl/`, the cocotb tests, its notes | one appended line in `LESSONS.md` |
| May run | Gowin timing, simulation | lint, formal, Gowin timing, cosim | nothing |
| Wall clock | 20 min | 30 min | 4 min |

- Search is greedy: K = 3 slots per round, N = 15 rounds. The best slot that beats the
  champion by more than 4.6% replaces it; every other slot is discarded.
- No weights change. Memory across rounds is the champion RTL, the run log (agents may read
  it) and the lessons file. Every run starts from V0 with an empty log and no lessons file.
- No web access. Agents run as separate OS accounts that cannot read the held-out kernels,
  results or the operator's files.

**Security caveat.** The gates prove functional correctness only. Accepted designs are not
screened for timing side channels. Accepted designs routinely add state that makes timing
depend on execution history: branch predictors (keyword match in title or hypothesis: 80 of
301 accepted rounds, 34 of 37 runs) and fetch-side buffers or caches (22 rounds, 16 runs).
Divider latency was not audited for operand dependence. Constant-time execution is out of
scope.

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
  to the agent's shell commands (`printenv` finds it). Those commands have
  no network (a probe's `curl` could not resolve any host), so a GPT agent
  could not call Anthropic's API with it, but anything it printed would
  have gone into its transcript, which Codex sends to OpenAI, and into
  files the harness keeps. No agent transcript, Codex session file, result
  file or archive on the host contains the token (all searched). The launch
  command also went into sudo's log and, as the systemd scope's
  description, into the journal (both root-only).
  (2) An Opus implementation agent started its formal self-check in the
  background (`( ... run_all.sh ... ) &`), polled it with `sleep`, and ended
  its session before it finished. Its solver processes had been reparented
  to init, so the harness's process-tree kill never saw them, and they ran
  on in the run's CPU slice for 30 minutes after the agent exited (16
  solvers at first), into time the run's next round would use. They ran in
  the host's PID namespace because the agent's sandbox was off (incident
  06). The journal
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
- Incident 06 (harness 2.6.0 campaign, stopped after 1.7 h in rounds 4-6,
  not scored, `research/runs/EXP-2026-09-28-v2-main/incident_06`): from
  harness 2.5 rc2 on, the Claude agents' shell commands ran without Claude
  Code's sandbox, in the 2.5 and 2.6 campaigns and their smokes. Codex was
  not affected. The 2.5 fix above put each agent's private TMPDIR under its
  worktree. Claude Code's sandbox binds its network proxy's Unix sockets
  under TMPDIR, and a Unix socket path may not exceed 107 bytes. Measured on
  the run host (Claude Code 2.1.283), the sandbox starts with a TMPDIR of up
  to 74 characters and fails from 75 on; the worktree TMPDIRs had 118. When
  the sandbox fails, Claude Code by default warns and runs the rest of the
  session unconfined ("Sandbox is enabled but failed to initialize: Failed
  to create bridge sockets after 5 attempts. Sandboxing is disabled for the
  rest of this session"). All 102 archived hypothesis and implementation
  sessions show that message at their first or second shell command. The
  scribes, whose TMPDIR under the clone root has exactly 74 characters,
  stayed sandboxed.
  Unconfined, a command ran as the run's agent account in the host's PID and
  mount namespaces, with network access. The account boundary held: the
  account cannot read other runs' clones, the operator's files or the
  credential store, and /proc shows it only its own processes, so nothing
  reached another run. Within a run, an agent could see and signal its
  sibling slots' processes.
  An audit of all 2,083 shell commands in the affected Opus transcripts
  found no network use and no access outside the run's clone and the
  agent's own CLI home. 22 commands listed processes to follow a formal
  self-check. With the sandbox off, these counted the sibling slots' solvers
  too (up to 91 at once), and three showed sibling agents' CLI command
  lines, which carry their prompts (the same hypotheses are in the clone's
  shared files). Two ran `pkill -f` with a pattern that matches any slot's
  formal run. Claude Code refused one because the pattern also matched its
  own CLI. The other, by implementation agent r6s1 at 05:28:46Z, raised the
  monitor's HIGH alert that led to this incident. By the transcripts'
  timestamps no sibling had a formal run at that moment (r6s2's ended at
  05:24:58Z, r6s0's began at 05:30:16Z), so it stopped only the agent's own.
  The failure was on record throughout. The message is in the transcripts
  from the first affected smoke on, and 13 Opus agents said in their final
  message that their commands ran unsandboxed. No monitor rule matched it,
  and the 2.5 and 2.6 validations checked outcomes (scores, broken slots,
  process scopes, credentials), not whether each sandbox actually started.
  The namespace evidence cited under incident 03 dated from 2.3.
  Fix (harness 2.7):
  - The Claude sandbox fails closed (`sandbox.failIfUnavailable`): a command
    that cannot be sandboxed fails instead of running unconfined.
  - Agents' private TMPDIRs go under a short per-run base outside the clone
    (26 characters, the same for every run), and the launcher refuses a
    TMPDIR over 48 characters.
  - Before its first round, each run starts one agent through the full
    launch path. The agent reports its PID and mount namespaces, whether it
    can reach the network and, for Claude, whether it can see the account's
    home. The run stops as a harness error unless the command ran confined.
    A negative control with the sandbox disabled fails this check (host
    namespaces, network open, home visible).
  - The monitor raises HIGH on either CLI's sandbox-failure message and on
    any agent-account process in the host PID namespace other than the CLIs
    and their launchers.
- Incident 07 (harness 2.7.0 campaign, stopped after 2.1 h, not scored,
  `research/runs/EXP-2026-09-28-v2-main/incident_07`): the harness passed
  each agent's prompt to its CLI as one command-line argument, and Linux
  caps a single argument at 128 KiB. The hypothesis and implementation
  prompts inline the core's RTL and its lessons file, which grow over a run.
  In round 7 the Opus run's prompt (96 KB of RTL, 16 KB of lessons) passed
  the cap, and every later slot failed to launch ("Argument list too long");
  with no slot able to run, the run could not change its RTL again. The Sol
  and Luna runs, with about 63-65 KB of RTL, had not reached the cap. V1 ran
  on macOS, which has no per-argument limit, and no earlier V2 run had grown
  this far. Fix (harness 2.8): the prompt goes to the CLI on standard input,
  not as an argument; both CLIs answer a 304 KB prompt through the full
  launch path, and the monitor raises HIGH when the harness cannot start an
  agent.
- Incident 08 (harness 2.8.0 campaign, batch 1, runs not stopped, scored;
  `research/runs/EXP-2026-09-28-v2-main/incident_08`, amendment 10): the
  runner writes a finished run's git bundle from inside the run's clone to
  `<results-dir>/<model>/rep<N>/repo.bundle`, and scores the held-out
  kernels only from that bundle. The campaign was launched with a relative
  results dir, so git resolved the path inside the clone and failed, the
  held-out scoring was skipped without an error, and the clone was deleted.
  Every smoke had used absolute paths. All 15 rounds of the three rep1 runs
  had run and each champion was preserved (final RTL, experiment log), so
  the metric was recomputed with the runner's own scoring code rather than
  the runs repeated: Opus from the fixture's root tree (identical in every
  clone) plus its saved final RTL, Sol and Luna from bundles a read-only
  watcher kept of their live clones until deletion (RTL byte-identical to
  the saved final RTL). For each, the loop's own eval on the rebuilt tree
  reproduced the champion's log row exactly (CoreMark, cycles, LUT4, Fmax
  per placement option) before `score_holdout` ran. Held-out iter/s: Opus
  7,769.6, Sol 5,767.6, Luna 3,042.7, 5 of 5 kernels validated in each.
  The runner was relaunched with absolute paths at the batch boundary (a
  watcher killed it the second the rep2 batch began, before any rep2 agent
  started); incident 09 then moved reps 2-6 to harness 2.8.1.
- Incident 09 (harness 2.8.0 campaign, rep2 batch stopped after 40 min, not
  scored; `research/runs/EXP-2026-09-28-v2-main/incident_09`, amendment 11):
  the orchestrator creates each round's slot worktrees from parallel threads,
  and git does not lock its worktree metadata. In Opus rep2 round 2, slot
  r2s0's `git worktree add` read sibling r2s2's
  `.git/worktrees/<name>/commondir`, which r2s2's own add had created but not
  yet written, and died ("failed to read .../commondir: Success"); the slot
  counted as broken before its agent started. An empty `commondir`
  reproduces the failure every time; the empty placeholder files Claude's
  sandbox leaves in the same directory do not. It was the first such failure
  in about 1,088 worktree creations across all archived runs, and it could
  hit any system. The three rep2 runs were stopped at 18:41:01Z, are reported
  as attempts, and rep2 reruns from V0. Fix (harness 2.8.1): the
  orchestrator's worktree and branch git commands run one at a time under a
  lock, and a failed worktree add is retried from a clean slate (up to three
  attempts, each retry logged). In a test with three slot threads, no two of
  these commands overlap; the same test fails on 2.8.0. The smoke of the new
  system (GPT-6.1 Sol, below) then found that a run stopped before its first
  round could not be rerun: its clone kept files only the agent account
  could delete, the runner had already revoked that account's access, and
  the rerun's clone failure was recorded as a final `failed`, so the run
  would never have been repeated. Fixed in 2.8.2 before any scored run.
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

## 7. Results

Six systems, 6 scored runs each (36 runs), N = 15 rounds, K = 3 slots, harness 2.8.2 for
every scored run. All runs start from V0 (5.4 MHz, CoreMark score 12.1). GPT-6.1 Sol replaced
GPT-6 Sol after one run (amendment 11); that run is an unscored pilot. Sonnet 5.5, GPT-6 Astra
and GPT-5.5 were added mid-campaign under amendment 13, with the same contract. Analysis:
`research/runs/EXP-2026-09-28-v2-main/analysis_final.md`.

Table 1. Final champions, geometric mean over 6 runs. Held-out is the pre-registered metric
(Gowin Fmax x geomean iterations per cycle over five hidden kernels). Rank interval: 95%
bootstrap.

| System (CLI) | Held-out iter/s | Rank interval | CoreMark score | Fmax MHz (median) | LUT4 (median) |
|---|---|---|---|---|---|
| Opus 5.5 (Claude Code) | 7,024 | 1 to 2 | 280 | 107.8 | 3,161 |
| Sonnet 5.5 (Claude Code) | 6,418 | 1 to 2 | 259 | 103.8 | 4,232 |
| GPT-6.1 Sol (Codex CLI) | 5,320 | 3 to 4 | 215 | 90.7 | 4,716 |
| GPT-6 Astra (Codex CLI) | 5,014 | 3 to 4 | 201 | 83.6 | 5,546 |
| GPT-5.5 (Codex CLI) | 3,595 | 5 to 6 | 143 | 63.9 | 2,948 |
| GPT-6 Luna (Codex CLI) | 3,538 | 5 to 6 | 137 | 64.6 | 2,934 |

- Primary test (pre-registered): Opus 5.5 vs GPT-6.1 Sol, ratio 1.320, 95% CI [1.183, 1.473],
  p = 0.0005. Opus 5.5 ranks higher.
- Amendment 01: GPT-6.1 Sol and Opus 5.5 both rank above Luna (Holm p 0.0007 and < 0.0001).
- Amendment 13, 12 pairs, Holm: 9 separate. The three that do not are Opus 5.5 vs Sonnet 5.5
  (1.095 [0.967, 1.238]), GPT-6.1 Sol vs GPT-6 Astra (1.061 [0.949, 1.187]) and GPT-5.5 vs Luna
  (0.984 [0.828, 1.170]). Every pair in different tiers separates (Holm p at most 0.0076).
- Run-to-run SD of ln(held-out score): 0.05 to 0.15 per system. At n = 6 that resolves
  differences of about 20% or more. It does not resolve the 6 to 10% gaps inside each tier.
- Transfer to unseen workloads (exploratory, not pre-registered): on 15 further Embench-IoT
  kernels no agent saw, the system order, the rank intervals and the three indistinguishable
  pairs are the same as on the held-out five. Run-level Kendall tau between the two scores is
  0.956, and Opus 5.5 leads on all 15 kernels. All 740 champion-kernel runs give correct
  results (`research/v2/extended_bench/`).
- Human-designed reference cores, measured on the same Gowin flow and stall model: VexRiscv
  MaxPerf, the best of ten, reaches 6,216 held-out iter/s, between tier 1 and tier 2. The other
  nine (VexRiscv NoCache 4,524 down to PicoRV32 1,741) score below every tier 2 champion
  (`research/v2/reference_cores/`).
- Correctness sensitivity (amendment 12): two champions had a formal-only branch. Opus rep2
  shrank its fetch store under formal; Sonnet 5.5 rep5 swapped its RAM register file for flops.
  Both pass all 53 checks when formal sees the synthesized RTL, so no run is removed.

Baselines and controls (amendment 15, run after the campaign):

- Textbook edit: V0 with its single-cycle divider replaced by a radix-2 iterative one (34
  cycles, the pipeline stalls until it finishes). It passes every gate and scores 2,645
  held-out iter/s (V0: 309). The whole gain is Fmax (5.4 to 46.6 MHz); the held-out kernels
  contain no divide, so their cycle counts do not change. Every scored run beats it (lowest:
  Luna rep6, 2,881); system means are 1.3x (Luna) to 2.7x (Opus) the textbook edit. In round
  1 the agents make the same move: 34 of the 35 designs accepted in round 1 change the
  divider (`research/v2/textbook_baseline/`).
- Random-mutation control: 3 runs of 45 slots, 1 to 3 seeded single-line edits per slot
  (operator swaps, ternary swaps, constant changes), no LLM. 0 of 135 accepted: 117 fail
  formal, 12 pass formal and fail cosim, 6 pass every gate without changing what the design
  does (an overridden default, unreachable cases, comment-only edits). Of the 18 that pass
  formal, 8 edit the real multiplier or divider, which formal replaces with stand-in
  formulas (ALTOPS); cosim rejects all 8. Blind edits to V0 do not get through the gates, so
  the systems' accepted rounds are not something the gates give away
  (`research/v2/random_control/analysis.md`).

Ablation (amendment 14): GPT-6.1 Sol run six more times without the lessons file (the
notes a scribe agent writes after each round and the next round's agents read). Full / no
lessons, held-out: 1.021, 95% CI [0.913, 1.140], p = 0.68, not distinguishable at n = 6. The
interval rules out a gain from the lessons above about 14%. Without lessons the six runs
spread twice as wide (SD of ln score 0.104 vs 0.048). The 15 extended kernels (1.024,
p = 0.67) and Artix-7 (1.147, p = 0.19) give the same answer
(`research/runs/EXP-2026-09-28-v2-main/analysis_ablation.md`).

Robustness of the ranking:

- Placement: the 42 finals rebuilt under all six Gowin place/route settings that change a
  build. Per design, the SD of ln Fmax across settings has median 0.022. Every setting, and
  the median, best and worst over settings, gives the same system order, Opus vs Sol 1.283 to
  1.334 (every p < 0.001), and the same 9 of 12 separating pairs (`research/v2/placement/`).
- Another FPGA (exploratory): every design synthesized for an AMD Artix-7 200T with Vivado
  2026.1. The split between the top four systems and {GPT-5.5, Luna} holds (8 of 8 pairs
  separate on both parts). The order inside the top four does not: Sonnet 5.5 7,511 > Opus
  6,724 > GPT-6.1 Sol 6,543 > Astra 6,236, and the primary pair gives 1.028 [0.813, 1.299].
  Kendall tau over the six systems 0.867. The agents' designs gain less from the faster
  fabric than the ten human cores (Artix-7 / Gowin Fmax 1.17 vs 1.67, p = 1.4e-7), and on
  Artix-7 two VexRiscv configurations score above every system's mean. Fifteen rounds of
  tuning against one vendor's timing report produce designs fitted to that part
  (`research/v2/xfpga/results/analysis.md`).

Formal checks run after scoring (exploratory):

- Deep formal (real multiplier and divider, no ALTOPS) on Opus rep1. At the vendored
  riscv-formal commit the DIV and REM specifications compute the unsigned quotient: the
  conditional `rs2 == 0 ? <all ones> : <overflow> ? <INT_MIN> : $signed(a) / $signed(b)`
  has unsigned arms, and Verilog then evaluates the division unsigned. So the contract's
  `make formal-deep` fails every correct divider; there is no record it was ever run. MUL
  proves in 3 s, DIVU in 1.9 h at depth 48; MULH, MULHSU and MULHU do not finish in 2 h at
  depth 20. Proving real arithmetic on all 36 finals is out of reach at this cost
  (`research/v2/deep_formal/`).

## 8. Limitations to state

- n = 6 per system separates tiers, not systems within a tier.
- The ablation covers one system (GPT-6.1 Sol). It rules out a lessons effect above about 14%
  for that system, not for the others.
- The ranking is a ranking on the Gowin contract. On Artix-7 only the split between the top
  four and {GPT-5.5, Luna} holds.
- Two contract gaps found after scoring, neither changing a scored result: formal has no bound
  on the fetch address (Opus 5.5 rep6 puts wrong-path addresses below 0 on 10 of the 15
  extended kernels, with correct results), and formal could check different RTL than
  simulation and synthesis (amendment 12; both affected champions pass on the synthesized RTL).
- Three systems joined mid-campaign; same harness, host and budget, but not interleaved with
  the first three.
- Gowin EDA Education edition: closed source, one version, one part; results
  are relative to that vendor's timer and placement.
- The placement-option median is effectively one value (options 1 and 2
  coincide), so the margin's independence assumption does not hold; the
  single-draw margin would be 6.5%. The final ranking does not depend on the
  setting (section 7), but per-round acceptances near the margin might.
- Formal ties the memory ready signals high and proves the M extension only
  with stand-in formulas. Real arithmetic is covered by cosim and unit tests;
  the deep-formal path in the contract cannot pass as vendored.
- One benchmark workload (CoreMark) drives optimization. The held-out five are small
  programs; the 15-kernel extended suite is exploratory, not pre-registered.
