# V2 descriptive analyses

Six descriptive analyses of the 36 scored runs of the V2 main campaign
(EXP-2026-09-28-v2-main): six systems x reps 1 to 6. They describe how the
runs went; they test no pre-registered hypothesis, and with n = 6 runs per
system most per-system correlations are too noisy to rank anything.

Systems, in the order of the paper's tiers ({Opus, Sonnet} > {Sol, Astra} >
{GPT-5.5, Luna}, geomean held-out iter/s 7024, 6418, 5320, 5014, 3595, 3538):
Opus 5.5 and Sonnet 5.5 (Claude Code), GPT-6.1 Sol, GPT-6 Astra, GPT-5.5 and
GPT-6 Luna (Codex CLI). Smokes, the GPT-6 Sol pilot and the no-lessons
ablation are excluded.

## Running

    python3 research/v2/analyses/run_all.py [--rebuild-transcripts]

Standard library only, about 20 s of one core with `--rebuild-transcripts`
(it re-parses the 36 `agent.full.log.gz` files), 3 s without. Each `aN_*.py`
also runs alone. Inputs are repo files only: `bench/v2/results*.jsonl`,
`bench/v2/<system>/rep<N>/` (log.jsonl, summary.json, agent.full.log.gz),
`research/v2/lessons/all_lessons.jsonl`, `research/runs/EXP-2026-09-28-v2-main/`
(analysis_final.json/.md, incident_08/holdout_rescored.jsonl, monitor/,
monitor_review.md) and `research/v2/reference_cores/results_sim/`.

| file | content |
|---|---|
| `common.py` | scored-row loader, outcome classes, Spearman with permutation p-values, table helpers |
| `transcripts.py` | parser for both transcript formats, shell-command classifier, cache builder |
| `a1_effort.py` ... `a6_transfer.py` | one analysis each; write `results/aN_*.json` and `results/aN_*.md` |
| `results/transcript_sessions.jsonl` | one row per agent session: role, finished or killed, tokens, check counts (no command text) |

The scored row of a run is the last `status=done` row for its (model, rep)
in `bench/v2/results*.jsonl`. Each scored run has exactly one such row. Opus
rep1 and Luna rep1 have no held-out score in that row (incident 08); their
held-out fields come from `incident_08/holdout_rescored.jsonl`, as in
`analyze_main.py`. Check: the 36 per-run held-out scores match the per-run
table of `analysis_final.md`, and the six system geomeans match
`analysis_final.json`.

Terms used below. **Spearman rho**: the correlation of two rankings (+1 =
same order, 0 = unrelated); p-values come from shuffling one ranking
(exact for n = 6, 20,000 shuffles for n = 36). **Pooled** rho uses all 36
runs; **within-system** rho ranks each run only against the other runs of
its own system before pooling, so a system that is both costlier and
stronger does not by itself produce a correlation. **Slot**: one of the 3
parallel candidates of a round (hypothesis agent, then implementation
agent, then the gates, then a scribe that may write a lesson).

## 1. Effort vs score (`a1_effort`)

Across systems, more tokens go with higher held-out scores; within a system
they do not. Pooled over the 36 runs, input tokens correlate with the
held-out score at rho = +0.83 and output tokens at +0.55, but with each run
ranked only within its own system both drop to about 0 (+0.01 and -0.01).
The pooled correlation comes from the two Claude systems using about 1.3 to
2 times the input tokens and 1.5 to 1.8 times the output tokens of the Codex
systems while also scoring highest. Wall-clock time is unrelated to score
(pooled +0.22, p = 0.20). Per-system rho with n = 6 ranges from -0.83 to
+0.89 and is not interpretable.

| system | input tokens (M) | output tokens (M) | wall clock (h) | API-equivalent cost (USD) | held-out iter/s |
|---|---|---|---|---|---|
| Opus 5.5 | 213 (203 to 232) | 3.20 (3.14 to 3.32) | 6.8 (5.5 to 9.2) | 199 (193 to 203) | 7,353 (5,991 to 7,770) |
| Sonnet 5.5 | 214 (194 to 250) | 3.01 (2.79 to 3.25) | 7.8 (6.7 to 9.3) | 115 (106 to 126) | 6,445 (5,642 to 7,144) |
| GPT-6.1 Sol | 139 (117 to 159) | 1.77 (1.47 to 2.04) | 12.8 (10.9 to 17.4) | n/a | 5,446 (4,940 to 5,528) |
| GPT-6 Astra | 166 (133 to 191) | 1.89 (1.46 to 2.17) | 10.8 (8.6 to 12.4) | n/a | 5,089 (4,353 to 5,641) |
| GPT-5.5 | 110 (105 to 138) | 2.07 (1.82 to 2.34) | 4.9 (4.0 to 7.2) | n/a | 3,520 (3,216 to 4,369) |
| GPT-6 Luna | 115 (95 to 144) | 1.88 (1.67 to 2.19) | 7.5 (6.0 to 7.8) | n/a | 3,669 (2,881 to 4,126) |

Median (min to max) over 6 runs. Tokens are gross: input includes cache
reads, output includes reasoning tokens.

- **Cost.** Every run's billed cost (`total_cost_usd`) is 0 because all
  runs used subscriptions. Claude Code also reports a list-price estimate
  (`api_equivalent_cost_usd`); the Codex CLI reports none, so cost exists
  only for the 12 Claude runs. Sonnet reaches 91% of Opus's geomean
  held-out score at 58% of Opus's API-equivalent cost.
- **Where the tokens go.** Implementation agents use 56% to 86% of each
  system's input tokens. GPT-6 Astra's hypothesis agents use 41%: they
  prototype ideas (Gowin timing in 69% of sessions, cosim in 66%, see
  section 3). GPT-6.1 Sol's hypothesis agents prototype as much, but their
  share (22%) is understated because most of them are killed at the time
  limit and report no usage (next point).
- **Codex totals are lower bounds.** The Codex CLI reports usage only in its
  final `turn.completed` event, so a session killed by the harness's time
  limit (20 min for hypothesis agents, 30 min for implementation agents)
  adds 0 tokens. GPT-6.1 Sol has a median of 28 such sessions per run
  (151 of its 270 hypothesis agents hit the 20-minute limit), Astra 10,
  Luna 1. Imputing each killed session at the median finished session of
  the same system and role raises Sol's median input to 177M and Astra's to
  191M; the tier pattern and the correlations above do not change. Claude
  Code totals need no correction (the runner recovers killed Claude
  sessions from per-message usage).
- **Wall clock** includes waiting for the host's shared formal and FPGA
  gates while concurrent runs held them, so it measures host load as much
  as the system.

## 2. Where candidates end (`a2_failures`)

Most candidates pass every gate and are rejected for not improving: 52% of
the 1,620 candidates do not beat the champion at all, 16% improve by 4.6%
or less (the acceptance margin), 13% beat the margin but lose to a better
slot of the same round, and 15.5% are accepted. Only 4.0% (65) fail a gate.
The formal gate stops the most gate failures (34 of 65, 52%), then FPGA
place and route (18, 28%), then cosim (8, 12%).

| system | accepted | lost to a sibling | improved below margin | no gain | gate failures |
|---|---|---|---|---|---|
| Opus 5.5 | 15.6% | 14.4% | 13.7% | 54.4% | 1.9% (5) |
| Sonnet 5.5 | 17.4% | 14.8% | 15.9% | 46.7% | 5.2% (14) |
| GPT-6.1 Sol | 20.0% | 19.3% | 11.9% | 45.9% | 3.0% (8) |
| GPT-6 Astra | 20.7% | 21.5% | 17.4% | 39.3% | 1.1% (3) |
| GPT-5.5 | 10.4% | 3.0% | 14.8% | 65.6% | 6.3% (17) |
| GPT-6 Luna | 8.9% | 2.2% | 21.5% | 60.7% | 6.7% (18) |
| all | 15.5% | 12.5% | 15.9% | 52.1% | 4.0% (65) |

Shares of each system's 270 candidates (15 rounds x 3 slots x 6 runs).

- The two weakest systems (GPT-5.5, Luna) have the fewest accepted
  candidates and almost never produce two margin-beating candidates in one
  round (2% to 3% lost to a sibling, against 14% to 22% for the others).
  GPT-6.1 Sol and Astra have the most accepted candidates (54 and 56), more
  than Opus (42) and Sonnet (47), with smaller steps each.
- The failure mix differs by system. Sonnet's 14 gate failures are mostly
  formal timeouts (10: `run_all.sh` took more than the harness's 2,700 s).
  Luna's are formal counterexamples (9) and place-and-route failures (7,
  designs too large for the device or unroutable). GPT-5.5's are
  place-and-route (9) and cosim (5). Astra failed only 3 times.
- Other classes: 3 hypothesis agents wrote no valid hypothesis (Sonnet 2,
  Luna 1; one Sonnet case is the EPERM harness interaction in section 5),
  2 sandbox violations (Sonnet, Sol), no build, lint or CoreMark failures.
- Counts match every results row once two conventions are known: the
  results rows count the baseline retest as accepted, and count
  placement_failed candidates as neither rejected nor broken.

## 3. Implementation agents' own checks (`a3_selfchecks`)

Nearly every implementation agent runs the harness's checks itself before
submitting: formal in 1,614 of 1,617 sessions (99.8%), cosim in 99%,
Verilator lint in 100%. The comparison the brief asked for (gate-failure
rate with vs without a formal self-check) therefore has 3 sessions on one
side and says nothing. What separates failing slots is the result of the
self-check: in the 1,517 slots whose last local formal result was a pass,
the formal gate never failed (0 of 1,517). All 34 formal-gate failures come
from slots whose agent last saw its own formal run fail (18: 15
counterexamples, 3 timeouts) or never saw a finished run (16, all
timeouts). The formal gate mostly records agents submitting designs they
knew failed, or running out of time.

| system | formal | formal after last RTL edit | cosim | Gowin timing | cocotb | killed at 30 min |
|---|---|---|---|---|---|---|
| Opus 5.5 | 99% | 69% | 100% | 83% | 82% | 0% |
| Sonnet 5.5 | 100% | 84% | 100% | 85% | 70% | 1% |
| GPT-6.1 Sol | 100% | 73% | 100% | 100% | 100% | 3% |
| GPT-6 Astra | 100% | 73% | 100% | 100% | 100% | 0% |
| GPT-5.5 | 100% | 96% | 99% | 1% | 67% | 0% |
| GPT-6 Luna | 100% | 83% | 97% | 88% | 12% | 4% |

Share of each system's implementation sessions that ran the check at least once.

- **GPT-5.5 almost never runs the scored timing flow** (4 of 270 sessions)
  and has the most place-and-route failures (9, none of them with a local
  timing run). Luna runs it in 88% of sessions and still has 7 (6 of them
  after a local timing run).
- **Luna submits failing designs**: in 11 slots its last local formal run
  had failures; 9 of them then failed the formal gate.
- **Sonnet's formal timeouts**: 9 of its 10 come from slots where the agent
  never saw its own formal run finish.
- **Hypothesis agents differ more than implementation agents.** GPT-6.1 Sol
  and Astra hypothesis agents prototype before proposing (Gowin timing in
  76% and 69% of sessions, cosim in 70% and 66%), and 56% and 23% of them
  are killed at the 20-minute limit. Opus and Sonnet hypothesis agents run
  mostly timing probes (timing 35% and 40%, cosim 1% and 5%). GPT-5.5 and
  Luna hypothesis agents run no checks.

Detection rules. Every shell command of a session (Claude Code `Bash`
tool calls; Codex `command_execution` items) is unwrapped (Codex's
`/bin/bash -c '...'`, nested `bash -c`), heredoc bodies are set aside, the
script is split into simple commands, and leading `VAR=value`, `timeout`,
`nice`, `env`, `nohup`, `setsid` are dropped. A check counts only when it is
the program run, never when its file is read or searched:

- formal: `bash formal/run_all.sh`, `./formal/run_all.sh`, `make formal`,
  `make formal-deep`, `sby <x>.sby` or `sby -f`, `python -m tools.eval.formal`
- cosim: `make cosim`, `python -m tools.eval.cosim`, `test/cosim/run_cosim.py`,
  the built harness binary `obj_dir/cosim_sim`, Python calling
  `tools.eval.cosim` or `run_coremark_ipc` (CoreMark on the same harness)
- Gowin timing: `make timing`, `make fpga`, `python -m tools.eval.gowin`,
  `python -m tools.eval.fpga`, `gw_sh`, Python calling `tools.eval.gowin` or `gw_sh`
- cocotb: `pytest`, `python -m pytest`, `make test`
- lint: `verilator --lint-only`, `make lint`
- "after last RTL edit": a formal run started after the session's last edit
  of `cores/bench/rtl` (Edit/Write, Codex file_change, or a shell command
  that writes an `.sv` file there: `sed -i`, redirection, Python
  `write_text`/`open(..., 'w')`, `cp`/`mv` into rtl, `git checkout`)
- local formal result: the last `Formal: N passed, M failed` line (printed
  by `run_all.sh`) in any command output the agent saw. "Pass" slots
  include passes followed by more RTL edits (319 of the 1,517).

Validation by hand: (1) a random sample of commands that mention a check
keyword but were not classified (about 25 per check from reps 2 and 5 of
every system) were all reads (`cat`, `sed -n`, `rg`), process listings
(`ps | grep sby`), `command -v`, or notes text, except one `eval $L` lint
call; sampled classified commands were all real invocations. (2) GPT-5.5's
4 timing sessions are exactly the 4 implementation sessions whose commands
contain `make timing`, `tools.eval.gowin` or `gw_sh`. (3) Luna rep1 r9s1,
which the operator's review says failed its own `reg_ch0` check before
submitting, is classified "fail" (52 passed, 1 failed). (4) An Opus slot
classified "never saw a result" was read in full: the agent ran formal
four times but read the outcome with `grep -c "DONE (PASS"` instead of
the summary line, so "none" means "result not seen in the summary form",
not "did not finish". Known gap: direct `yosys-smtbmc` calls are not
counted as formal (7 commands, Sol and Astra, all in sessions that also
ran `run_all.sh`).

## 4. Lessons (`a4_lessons`)

After each candidate the scribe (the same model) may write a one-line
lesson to LESSONS.md, which later hypothesis prompts include. The 36 runs
have 1,228 lessons: 244 from accepted candidates, 951 from rejected ones,
33 from gate failures. Systems differ mostly in how often the scribe writes
anything and how long the lessons are: Opus and GPT-5.5 write one for
nearly every candidate (40 to 45 per run), GPT-6.1 Sol for 44% of rejected
and 12% of failed candidates (18 to 30 per run). Claude lessons are 3.7 to
5 times longer (median 1,154 and 958 characters against 225 to 256).

| system | lessons (per run) | written for accepted / rejected / gate-failed candidates | median length |
|---|---|---|---|
| Opus 5.5 | 261 (42 to 45) | 98% / 96% / 100% | 1,154 |
| Sonnet 5.5 | 218 (32 to 40) | 96% / 80% / 43% | 958 |
| GPT-6.1 Sol | 144 (18 to 30) | 96% / 44% / 12% | 251 |
| GPT-6 Astra | 168 (21 to 37) | 96% / 54% / 33% | 256 |
| GPT-5.5 | 260 (40 to 45) | 100% / 96% / 88% | 237 |
| GPT-6 Luna | 177 (27 to 34) | 100% / 65% / 28% | 225 |

Topics (keyword rules in the script; "primary" = the specific topic named
first in the lesson). Overall primary topics: forwarding and hazards 28%,
branch prediction 27%, fetch and caches 15%, divider 10%, multiplier 9%,
formal/RVFI 2%, process/tooling 4%; cosim essentially never (it is almost
never why a candidate failed). Nearly every lesson also discusses Fmax or
the critical path (88% of lessons, since the fitness is Fmax x CoreMark
iterations per cycle). GPT-6 Astra stands out with divider lessons (28%
primary; 24 of its 47 come after round 5, as it kept retiming its
divider), Opus and GPT-5.5
with branch prediction (31%, 32%). Multi-label shares are inflated for the
Claude systems because their lessons are longer and name more topics.

Repetition. A later hypothesis "repeats" an earlier one when their title
word sets overlap with Jaccard similarity of at least 0.5 (shared words
divided by all distinct words), the earlier candidate was rejected or
failed, and the scribe wrote a lesson on it. Repeats are rare: 24 of 1,512
later candidates (1.6%). They concentrate in GPT-6 Luna (12, 5%) and GPT-5.5
(8, 3%); Opus 2, Sonnet 1, Sol 1, Astra 0. Of the 24, 2 were accepted
(one is Sol re-applying a divider tweak on a new champion), 21 were
rejected and 1 failed a gate. Part of the Luna and GPT-5.5 excess is a length effect: their
titles have a median of 4 content words against 12 to 14 for Claude, and
two 4-word titles reach J = 0.6 with 3 shared words. Typical match: GPT-5.5
rep2 "ID-stage direct-JAL predictor" (improved below margin), then "Target-carry
direct-JAL predictor" and 8 rounds later "Opcode-fast direct-JAL predictor"
(both no gain).

Representative lessons (shortened):

- GPT-6.1 Sol rep6, accepted (+735%): "Moving combinational DIV/REM (`/` and
  `%`) out of the shared ALU into a registered iterative divider removes
  their timing cost from ordinary instructions, letting Fmax gains outweigh
  CoreMark's added divide stalls."
- Opus 5.5 rep1, rejected: "once the combinational `/`/`%` is gone, the
  single-cycle 33x33 DSP multiply is not on the critical path ... a unit
  should only come off the EX path when the timing report shows it is
  critical."
- GPT-6 Luna rep5, rejected: "Even a tiny direct-mapped BTB puts indexed
  tag/counter reads and target selection on the IF next-PC path, and their
  timing cost outweighed saved CoreMark loop-redirect bubbles."
- GPT-6 Astra rep1, rejected (+4.2%): "Capturing completed MEM results and
  PC/immediate operands in ID reduces EX forwarding to two-input muxes but
  recovers too little Fmax ... to clear the 4.6% acceptance margin."

## 5. Monitor alerts (`a5_monitor`)

A transcript monitor scanned every agent command and message during the
campaign and raised HIGH alerts on possible sandbox or contract breaches.
Of the 132 operator review rows on HIGH alerts of scored runs, 121 judged
the alert benign (a real action that could not affect anything outside
the agent's own slot), 9 a false positive (the rule matched words, for
example "kill" in RTL), 1 harness-caused and 1 real. Neither of the last two
affected a score.

| system | HIGH (unique) | MEDIUM (unique) | review rows: benign / false positive / harness / real |
|---|---|---|---|
| Opus 5.5 | 33 | 543 | 27 / 6 / 0 / 0 |
| Sonnet 5.5 | 78 | 713 | 72 / 1 / 1 / 0 |
| GPT-6.1 Sol | 12 | 652 | 14 / 2 / 0 / 0 |
| GPT-6 Astra | 10 | 626 | 13 / 0 / 0 / 0 |
| GPT-5.5 | 4 | 72 | 4 / 0 / 0 / 1 |
| GPT-6 Luna | 1 | 163 | 2 / 0 / 0 / 0 |

"Unique" drops an alert's second copy from the archived transcript. A
review row can cover several alerts and runs.

- The Claude systems raise most HIGH alerts, from two Claude-specific
  patterns: `pkill` of their own background formal or timing runs
  ("kills processes": Sonnet 52, Opus 17; the pattern also matches the
  command's own shell, which exits 143, and each sandboxed command has its
  own process namespace, so nothing else is reachable) and Claude Code's
  sandbox failing closed on a single command when the harness removed a
  worktree it had listed ("sandbox failed to start": Sonnet 19, Opus 9).
- GPT-6.1 Sol's and Astra's HIGH alerts are mostly read-only listings of a
  sibling or earlier slot's worktree (4 each) and Yosys runs on their own
  RTL that the rule files under the non-scoring FPGA flow (5 and 3).
  GPT-5.5 and Luna raise 4 and 1. MEDIUM alerts are mostly process listings
  (`ps`, 1,555 of 2,876).
- Real (GPT-5.5 rep1, round 4): an implementation agent cleaning up deleted
  a sibling slot's live formal work directory, costing that sibling a
  re-run of its self-check; harness evals run elsewhere, so no score was
  affected. Harness (Sonnet rep3, round 12): the hypothesis agent also
  copied its YAML into the main clone, and the harness's later copy failed
  with EPERM, which made the slot `hypothesis_gen_failed`.
- Two in-scope operator checks outside the HIGH table also found harness
  issues: placement-failed worktrees left in the clone, readable by later
  agents of the same run, and incident 08 (held-out scoring skipped for
  Opus rep1; rescored).

The alert time stamps in `alerts.jsonl` are the run host's local time
(CEST, UTC+2); the script converts them to UTC and keeps alerts raised
after each scored attempt started, which drops 29 alerts of stopped
earlier attempts and smokes.

## 6. Transfer from CoreMark to the held-out kernels (`a6_transfer`)

CoreMark progress transfers almost one for one. Across the 36 champions the
held-out score is 24.2 to 26.7 times the CoreMark score (median 25.0), and
the two scores rank the runs nearly identically (Spearman +0.996 pooled,
+0.94 within systems). Both scores multiply the same Fmax by an
iterations-per-cycle figure, and Fmax alone explains most of it (rho +0.94
with the held-out score). Iterations per cycle also transfer (CoreMark IPC
vs held-out IPC: +0.95 pooled, +0.94 within systems).

| system | CoreMark iter/s | held-out iter/s | held-out / CoreMark (min to max) | Fmax MHz | CoreMark iter per M cycles | held-out iter per M cycles |
|---|---|---|---|---|---|---|
| Opus 5.5 | 290.1 | 7,353 | 25.25 (24.22 to 25.54) | 107.8 | 2.57 | 65.2 |
| Sonnet 5.5 | 260.9 | 6,445 | 24.92 (24.16 to 25.03) | 103.8 | 2.44 | 60.9 |
| GPT-6.1 Sol | 217.4 | 5,446 | 24.67 (24.29 to 25.46) | 90.7 | 2.41 | 58.9 |
| GPT-6 Astra | 203.5 | 5,089 | 25.00 (24.85 to 25.09) | 83.6 | 2.49 | 62.1 |
| GPT-5.5 | 140.7 | 3,520 | 25.35 (24.51 to 26.00) | 63.9 | 2.23 | 56.2 |
| GPT-6 Luna | 138.3 | 3,669 | 25.53 (24.94 to 26.67) | 64.6 | 2.24 | 57.0 |

Medians over 6 runs. "Held-out iter per M cycles" is the geometric mean over
the five kernels of iterations per million cycles (held-out score / Fmax).

- The worst-transferring runs fall 2% to 3% below the median ratio:
  Sonnet rep2 (24.16), Opus rep4 (24.22), Sol rep3 (24.29), Sol rep1, and
  GPT-5.5 reps 2 and 4. In each the weakest kernel is `edn` (a DSP-style
  filter kernel heavy in multiply-accumulate), at 0.86 to 0.93 of its
  typical ratio. The best transfer is Luna rep4 and rep2 (26.7, 26.4) and
  GPT-5.5 rep5 (26.0). Lower-scoring runs have slightly higher ratios
  (Spearman of CoreMark score vs ratio -0.28, p = 0.09).
- The ten open-source reference cores, run through the same ELFs, stall
  model and scoring, span 24.0 to 27.3 (VexRiscv MaxPerf 27.3), the same
  band, so the champions show no sign of CoreMark-specific tuning beyond a
  few percent.

## Data problems found

- Opus rep1 and Luna rep1 results rows have no held-out fields (incident 08);
  filled from `holdout_rescored.jsonl`. All 36 per-run values then match
  `analysis_final.md`.
- `total_cost_usd` is 0.0 in all 36 rows; `api_equivalent_cost_usd` exists
  only for Claude runs, in the results row for Opus rep1 and Sonnet, and
  only in `summary.json` for Opus reps 2 to 6.
- Codex token totals exclude every session killed by the harness's time
  limit (163 Sol sessions, 65 Astra, 11 Luna over 6 runs each); see
  section 1 for the imputed correction.
- `agent.full.log.gz` also contains `<worktree>/.agent.log` copies of
  implementation sessions for placement-failed slots (their worktrees were
  not deleted, the harness bug in section 5). The parser drops them; with
  that, per-run token sums from the transcripts equal the results rows
  exactly for all 36 runs.
- The results rows' `accepted` includes the baseline retest, and
  `rejected` and `broken` both exclude placement_failed candidates.
- 3 slots have no implementation transcript (hypothesis agent failed), so
  section 3 covers 1,617 of 1,620 slots.
- `all_lessons.jsonl` matches the `lesson` fields of the 36 log.jsonl files
  exactly (1,228 lessons); its other 21 rows are the GPT-6 Sol pilot and a
  smoke.
- Monitor alert time stamps are local time (CEST), not UTC.
