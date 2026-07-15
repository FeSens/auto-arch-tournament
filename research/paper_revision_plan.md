# HWE Bench revision plan (post-MLCAD-2026 reject)

Written 2026-07-15. Source reviews: `research/review_log.md`.
Paper under revision: `paper/main.tex`. Data: `bench/results.jsonl`,
`bench/leaderboard.csv` (snapshot has grown since submission: the paper
froze 17 done reps over 6 configs; the bench now holds ~27 done reps
over 10 configs, including gpt-5_6-luna/terra at 3 reps, gpt-5_6-sol at
1 valid rep, gemini-3_1-pro at 3 reps).

## Thesis of the revision

The reject was not about the harness (both borderline reviewers praised
the gate design and the artifact). It was about evidence: no attribution
control, thin reps with a best-of-run headline, one workload, one
external baseline, plus method-transparency and tone issues. The
revision therefore adds four experiments (E1-E4), one optional (E5), and
a full rewrite pass (W1-W9). Every experiment below gets a
`research/runs/<RUN_ID>/prereg.yaml` before launch; the stubs here are
the content of those files.

## Target venue (decision pending, user)

| Option | Deadline | Fits |
|---|---|---|
| ICLR 2027 (Brazil) | abstract 2026-09-19, full 2026-09-24 | E1-E3 + E5 + rewrite; benchmark papers native there (SWE-bench precedent); 9-10 pages + appendix |
| DATE 2027 (Dresden) | abstract 2026-09-13, full 2026-09-20 AoE | E1-E4 + rewrite, tight but feasible; 6-page CAD framing |
| DAC 2027 (Long Beach) | abstract 2026-11-11, manuscript 2026-11-18 | everything incl. E6 second-fixture loop |
| MLCAD 2027 | ~2027-05 | fallback, same community as original reviews |

ICLR and DATE deadlines are the same week, so they are mutually
exclusive on this cycle (both prohibit dual submission). Choosing ICLR
also forfeits DAC 2027 as a fallback (ICLR notification ~Jan 2027 is
after DAC's Nov 18 deadline); the fallback ladder from an ICLR reject
is ICML 2027 (~late Jan), NeurIPS 2027 D&B (~May), MLCAD 2027 (~May).

Recommendation: ICLR 2027. The contribution is an LLM-agent benchmark;
its users and citers are the ML/agents community, and the MLCAD
objections that survive (attribution, sample size, ablations,
best-of-run framing) are exactly ICLR-reviewer objections, while the
CAD-scope objections (one FPGA target, one CAD flow) carry less weight
there. Deadlines verified 2026-07-15 via aggregators; re-verify on
iclr.cc when the official CFP posts.

### ICLR-specific deltas (apply only if ICLR chosen)

- E5-lite ablations move P1 -> P0 (scaffold ablations are expected).
- Add 1-2 model families at n>=3 (Claude, optionally DeepSeek) via the
  same opencode runtime: answers "mostly closed models" and makes the
  leaderboard read as a model-family comparison, which is what ICLR
  readers come for.
- Rewrite for an ML audience: define CoreMark, RVFI, P&R, Fmax from
  scratch; related work repositions around agent evals and
  evaluator-guided search (SWE-bench, FunSearch/AlphaEvolve) with CAD
  benchmarks as the secondary cluster; MLCAD's 6-page compression
  reverses into a 9-10 page structure with appendix (full failure
  taxonomy, per-run trajectories, prompt texts, gate definitions).
- Add a contamination/longevity paragraph: fixture RTL becomes public
  training data post-release; the objective is physical and unbounded,
  so memorizing V0 does not saturate the bench, but champion diffs from
  released runs could be regurgitated; versioned fixtures (new frozen
  cores per bench version) are the mitigation.
- E4b (ECP5 second target) becomes optional polish; E4a (in-flow
  PicoRV32/Ibex references) stays, it is cheap and anchors V0.

---

## V2 scope (decided 2026-07-15, author + assistant)

Supersedes the E2 rep table and merges the ICLR deltas. Venue: ICLR
2027 (abstract 2026-09-19, full 2026-09-24). Branch: `bench-v2`.
Paper: rewritten from scratch for an ML audience in `paper/v2/`
(old sources kept for reference). Slip rule unchanged: miss the
Aug 31 checkpoint, retarget ICML 2027 (~late Jan, verify CFP).

### Model x runtime matrix

Focus per author: gpt-5.4, gpt-5.5, gpt-5.6 (luna/terra/sol);
deepseek v4 later, cost-gated. Kimi/gemini keep their existing reps as
an extended cohort (no new compute). Two subscription lanes (opencode
and codex CLI) run in parallel.

| Arm | Runtime | Configs | Target n | New reps |
|---|---|---|---|---|
| Primary | opencode | 5_4_xhigh, 5_4-mini, 5_5_medium, 5_5_high, 5_5_xhigh, 5_6-luna, 5_6-terra, 5_6-sol | 5 | ~18 (sol needs +4, others +2) |
| Runtime factor | codex | one per family: 5_4_xhigh, 5_5_xhigh, 5_6-sol | 3 | 9 |
| E1 controls | n/a / opencode | static x1, random-mutation x3, naive-LLM x3 | - | 7 |
| E5 ablations (now P0) | opencode | gpt-5_5_medium: lesson-log-off, K=1 equal budget, best-of-45 | 3 each | 9 |
| Scaling (bet C) | opencode | best config (5_5_xhigh), N=45 rounds | 3 | ~9 rep-equiv |
| DeepSeek v4 (later) | opencode | deepseek-v4 | 3 | 3, est. $15-30/rep, cap $100 |

Total ~48 new rep-equivalents, ~320 h, ~7-9 days of dual-lane 24/7
compute. VERIFY before starting: the local box can run two eval lanes
concurrently (formal + nextpnr are the CPU bottleneck); if not,
single-lane is ~14 days and the Aug 31 checkpoint tightens.

### Defaults folded in (no further approval needed)

1. Runtime as a controlled factor: same model through opencode vs
   codex, paired analysis, reported scaffold variance. Agent
   benchmarks confound model with scaffold; publishing the measured
   confound is itself a contribution. Requires hardening the codex
   runtime path (currently experimental per project memory) and a
   prompt/limit parity audit so runtime is a clean single factor.
2. Cost-normalized leaderboard: every row carries tokens, $, wall
   clock, evals-to-best, and fitness-gain-per-dollar. Serves the
   deepseek story and the cost-aware-benchmark critique.
3. Hierarchical statistics: mixed-effects model (config fixed effect,
   rep random effect) plus bootstrap CIs; analysis plan preregistered
   in-repo before the new reps run.
4. Correctness-discipline metric: per-model first-failing-gate
   profile elevated to a headline secondary metric (formal-violation
   rate = plausible-but-wrong-RTL rate).
5. Adoption engineering: semver bench release, one-command
   reproducible eval, CI smoke run, croissant metadata
   (`tools/bench/croissant.py`), refreshed public leaderboard site,
   submission-protocol doc.
6. Harness burn-in gate BEFORE any big compute: root-cause the sol
   startup failures (2 discarded reps = a real bug, not noise),
   de-track `__pycache__`, runner resume robustness, dual-lane
   support, runtime parity audit. Exit criterion: 3 consecutive lite
   smoke tournaments green on BOTH runtimes.

### Adopted bets

- Transfer score as a contract metric (extends E3): bench v2 reports
  a (fitness, transfer) pair per run; transfer = held-out geomean
  (Dhrystone + 4-6 Embench kernels), never optimized against, never
  in agent context; kernels validated on V0 before scoring anything.
- Scaling curves: 3x N=45 long-horizon runs; figure = champion
  fitness vs iteration with per-round accept probability.

### Declined / deferred (gate 9: logged, not deleted)

- Human expert baseline: declined 2026-07-15 (author time cost).
  Paper lists it as future work; the slot CLI already permits a human
  driver, so the hook stays documented.
- Renewable fixture family (V0b/V0c from the same spec, one private):
  deferred to bench v3; paper carries it as the contamination
  mitigation design in Limitations/Future Work.

---

## P0 experiments (blocking resubmission)

### E1. Attribution controls through the identical gates  [R2.b, R3.c]

The decisive experiment. Three arms, same N=15 x K=3 x 46-row shape,
same gates, same strict-improvement rule, TARGET=bench fixture:

- E1a `static` (exists, `tools/agents/static_agent.py`): no-op edits.
  Harness noise floor; expected delta 0% with pinned P&R seeds. Run 1
  rep only to produce the logged row for the paper.
- E1b `random-mutation` (new `tools/agents/random_agent.py`, provider
  `random`, routed like `static` via `_runtime.build_agent_cmd`): no
  LLM. Pre-registered mutation operator set over the champion RTL,
  applied k ~ Uniform[1,3] mutations per slot with a seeded RNG:
  constant/literal perturbation, binary-operator swap within type class,
  signal-connection rewire within a module, pipeline-register
  duplication/deletion, if/else branch swap, mux-arm swap, dead-code
  deletion of an unreferenced signal. Operators chosen to be
  syntactically valid by construction so the control is not a
  lint-fails-instantly strawman; semantic validity is exactly what the
  gates test. 3 reps, RNG seeds 101/102/103.
- E1c `naive-LLM`: gpt-5_5_medium through the same runtime with a
  stripped prompt (no lesson log, no prior-round outcomes, no metrics,
  no hypothesis scaffold; instruction is only "make a small change to
  the core that you believe improves Fmax x CoreMark/MHz"). Isolates
  the benchmark scaffold from the raw LLM prior. 3 reps.

Prereg stub (E1b shown; E1c analogous):
```yaml
question: Do blind syntactic mutations through the identical gate chain
  produce accepted fitness improvements at a rate comparable to LLM agents?
hypothesis: Random mutation accepts ~0 strict improvements per 46-row rep;
  any accepted delta is small (<5% cumulative).
baseline_run_id: paper-snapshot-17rep (results.jsonl, status=done, 6 configs)
primary_metric: final champion fitness (iter/s) per rep; secondary
  accepted-count per rep, gate-pass rate, first-failing-gate distribution
success_rule: The claim "agent editing beats gated random sampling" is
  supported iff every LLM config mean exceeds the E1b mean with
  non-overlapping 95% bootstrap CIs AND E1b accepted-count mean < 1.
  If E1b acceptance is materially nonzero, the paper reframes from
  "agent optimization" to "gated-search benchmark" per the pre-agreed
  wording in W4.
seeds: [101, 102, 103]
```

Cost: E1b is eval-only; mutated candidates that die at lint cost
seconds, survivors cost a full eval (~10-20 min). Estimate 1-3 h/rep,
zero token cost. E1c ~6 h/rep at subscription cost. Build effort for
the mutation agent: ~1-2 days incl. unit tests (mutations must apply
inside the write fence only).

Paper claim moved: turns "lower-bound measurement of the full gated
system" into an actual attribution statement (or an honest negative).
Lands in Results as a control row in the leaderboard table plus a
paragraph; removes the reviewers' central objection either way.

### E2. Reps to n>=5 and a pre-registered stats protocol  [R1.d, R2.c]

Bring every paper-headline config to 5 completed reps. Existing 3 (or
2) reps count; confirmatory reps are new (disjoint provider sampling by
construction; runs are not seed-replayable, which the paper states).

New reps needed (each ~46 rows, wall clock from leaderboard s/iter):
- gpt-5_4_xhigh +2 (~10 h/rep), gpt-5_5_xhigh +2 (~6 h),
  gpt-5_5_high +2 (~7 h), gpt-5_5_medium +2 (~7 h),
  gpt-5_4-mini +2 (~25 h, the slow one), kimi-k2_6 +3 (~9 h, ~$14/rep),
  gemini-3_1-pro +2 (~6 h, ~$28/rep).
- gpt-5_6-luna/terra/sol stay an "extended cohort" at n=3 (sol needs
  2 rerun reps to replace the discarded startup failures) unless time
  allows n=5.

Total ~15 core reps, ~120 h serial, ~$90 API cost. Parallelize across
worktrees if the box allows; otherwise ~2-3 weeks calendar including
babysitting.

Stats protocol (pre-registered before the new reps run, frozen in
`research/runs/EXP-...-e2-stats/prereg.yaml`):
- Per-config: mean +/- sample std AND 95% bootstrap CI (10k resamples),
  n stated everywhere a number appears.
- vs V0: exact binomial sign test over all done reps (every rep's final
  champion > 282.82; at n=27+ this is p < 1e-8) plus per-config
  one-sample Wilcoxon against 282.82.
- Config-vs-config: claimed only where 95% CIs are disjoint; everything
  else labeled "not separated at n=5". Expected survivors: top tier vs
  {gpt-5_4-mini, kimi, gemini} and the effort-ladder trend
  (gpt-5_5 medium/high/xhigh, Jonckheere-Terpstra or rank regression);
  pre-register that a full ranking is NOT claimed.
- Headline framing: abstract reports the pooled/median run improvement
  and per-config means with CIs; 525 iter/s appears only as
  "best single run (max over N reps)".

### E3. Held-out workload evaluation  [R2.e, R1.b]

Score every final champion (plus V0, plus the best run's four-step
trajectory) on workloads the loop never optimized against. No new
tournament runs; simulation-only reuse of existing champions and their
already-measured Fmax.

- Workloads: Dhrystone plus an Embench-IoT subset (aha-mont64, crc32,
  matmult-int, edn; pick 4-6 kernels that fit the 1 MB memory map and
  the existing crt0/link.ld). Port effort ~2-4 days (MMIO putchar,
  start/stop markers at 0x10000100/104, same backpressure injection).
- Metric per design: held-out iter/s = median Fmax x kernel iter/cycle
  (identical formula, per kernel and geomean).
- Analysis: transfer ratio = held-out geomean gain / CoreMark gain, per
  design and per accepted-edit class (structural / micro_opt /
  predictor). The replay predictor's contribution is directly separable
  in the best-run trajectory (its accept is a single diff).

Prereg stub:
```yaml
question: How much of the CoreMark fitness gain transfers to workloads
  the loop never saw?
hypothesis: Structural and micro_opt gains (Fmax-side) transfer near
  fully; predictor-class cycle gains transfer partially or not at all.
primary_metric: geomean held-out fitness gain over V0 per final champion
success_rule: Report the transfer distribution whatever it is. The
  "not merely workload overfitting" claim is made iff the median
  champion keeps >=50% of its CoreMark gain on the held-out geomean.
  No re-optimization against held-out kernels, ever (they stay held out
  for future bench versions).
```

Guard (gate 5): validate each ported kernel on V0 against known-good
output/CRC before scoring any champion, and keep held-out binaries out
of the agent-visible tree.

### E4. Baseline and scope widening, cheap tier  [R1.b, R2.d, R3.a]

- E4a: finish the pending in-flow reference measurements in
  `bench/reference-cores.md`: PicoRV32 and Ibex (small) through the
  same Yosys+nextpnr flow, 3-seed median, plus their published
  CoreMark/MHz. Fills Table 2 with two more comparators, kills the
  "one external point" objection at reference level. ~2-3 days.
- E4b: re-run P&R of V0 + the two Pareto champions on a second nextpnr
  target (Lattice ECP5 via nextpnr-ecp5, same open flow family) and
  report Fmax deltas. Shows gains are not Gowin-artifact. Feasibility
  check first (~1 day); ~2-3 days total. If ECP5 is not practical in
  time, scope down to a sentence acknowledging single-target validity.

### W. Paper rewrite  [R1.c, R1.e, R2.c, R2.f, R3.b, R3.d]

1. Tone pass. Delete or neutralize, verbatim hit list: "We ask a
   direct question", "HWE Bench is that setup", "the gate is doing its
   job", "broken silicon", "Acceptance is rare by design" stays but
   loses editorial framing. General rule: no sentence whose subject is
   the paper performing ("This work asks/argues/is that setup").
2. De-repetition. The scope/attribution caveat currently appears in
   abstract, intro, method, discussion, and conclusion; keep it once in
   full (discussion) and once in one clause (abstract). Cut duplicate
   restatements of the gate chain (currently intro, 2.1, 3.3, 4).
3. Restructure per R3.d: fold old Sec 2.1 (fixture and evaluation
   stack) into Section 3 as "3.1 Fixture and evaluation stack"; Related
   Work compresses to ~0.75 page.
4. Reframe headline per E1 outcome and E2 protocol: abstract leads with
   config means/CIs and the sign-test statement; 525 labeled best-of-N;
   title/framing keeps the benchmark first ("HWE Bench: a
   correctness-gated benchmark for iterative LLM hardware
   optimization") and claims agent attribution only as far as E1
   supports.
5. V0 provenance paragraph (R1.c), in Method: V0 was written from
   scratch for this benchmark (repo phases 0-8, `docs/
   bootstrap-prompt.md`), not derived from an existing open-source
   core; a deliberately conservative 5-stage in-order RV32IM (no branch
   prediction, no caches, hardware M) frozen at a git tag; its 283
   iter/s starting point sits below tuned references by design, to
   leave measurable headroom, and the paper reports both absolute and
   relative endpoints. DECIDED 2026-07-15 (author): disclose plainly
   that V0's RTL was drafted by an LLM agent from a human-written
   specification (the phased bootstrap, `docs/bootstrap-prompt.md`),
   validated by the full gate stack (riscv-formal, ISS cosim, CoreMark
   CRCs) and frozen at a git tag before any benchmark run. External
   anchors (VexRiscv, E4a PicoRV32/Ibex) locate V0's absolute quality
   independently of authorship.
6. Agent-scope subsection (R3.b): a small table of (a) observation:
   champion RTL (~56 KB inlined), architecture contract, invariants,
   last-5 round outcomes, curated lesson log, core metadata; (b) action
   space: unrestricted file edits within the write fence (RTL + cocotb
   tests), no fixed operator menu; (c) learning: no weight updates,
   in-context only, lesson log is the only cross-round memory, each rep
   starts from the same fixture with an empty log.
7. Greedy-search discussion (R3.c): acknowledge 1+lambda hill-climb
   with strict improvement is exploitative; note the harness already
   supports a Pareto acceptance mode (disabled in the snapshot for a
   single scalar objective); position acceptance-rule exploration
   (epsilon-tolerance, restarts, population methods) as benchmark
   configuration, and cite the E1c/E5 data if run.
8. Security caveat (R2.f), one paragraph in Limitations: RVFI proves
   functional correctness only; accepted edits are not screened for
   timing side channels, and two accepted classes are explicitly
   data-dependent-timing (multi-cycle divider latency, PC-indexed
   replay hits), so constant-time properties are out of scope.
9. Mechanical: fold the grown snapshot (define ONE new frozen snapshot
   from current + E2 reps, reconcile LEADERBOARD/results.jsonl rows the
   way REVISION_REPORT.md sec 1 did); scrub the NeurIPS label in
   `BENCH_METHODOLOGY.md`; re-mint the anonymized artifact under a
   neutral slug (old slug embeds the repo name); keep the no-em-dash
   voice rule.

---

## P1 experiments (strongly recommended, DATE-feasible)

### E5-lite. Harness ablations, one config  [R3.a, R3.c]

On gpt-5_5_medium (cheapest stable config, std +/-11):
- lesson-log OFF, 3 reps (~21 h): tests the reflective-memory claim.
- K=1 greedy at equal budget (N=45 rounds x K=1), 3 reps (~21 h):
  tests the tournament/branching claim.
- best-of-45 from V0 (no merge, pure sampling), 3 reps (~21 h): tests
  iteration vs sampling; complements E1.
Success rule (prereg per arm): the corresponding contract feature is
claimed useful iff full-harness mean beats the ablated mean with
non-overlapping 95% CIs at n=3+3; otherwise reported as "not separated".

## P2 (DAC-timeline only)

- E6. Second in-flow fixture loop: PicoRV32 (riscv-formal has upstream
  bindings) wrapped to the harness imem/dmem+RVFI contract, then 2-3
  configs x 3 reps on the new fixture. The strongest possible answer to
  "one starting core", ~2-3 weeks of engineering plus ~60 h compute.
- E7. gpt-5_6 cohort to n=5 and any newly released frontier model, to
  keep the leaderboard current at submission time.

---

## Sequencing (ICLR 2027, v2 scope)

| Weeks (2026) | Work |
|---|---|
| Jul 15 - Jul 31 | Harness burn-in gate (sol bug root cause, dual-lane, codex parity); build E1b mutation agent + E1c variant; port held-out kernels; write all prereg.yamls; verify dual-lane CPU capacity |
| Aug 1 - Aug 20 | Compute window opens ONLY after burn-in passes: primary matrix reps, codex arm, E1 controls, E5 ablations, scaling runs; E4a references in parallel; paper/v2 outline + method sections drafted alongside (diary = draft) |
| Aug 21 - Aug 31 | Freeze snapshot v2; hierarchical stats; transfer scoring + analysis; figures. CHECKPOINT Aug 31: controls + primary matrix done or slip to ICML |
| Sep 1 - Sep 19 | Full from-scratch rewrite in paper/v2; red-team pass against review_log.md point-by-point; abstract Sep 19 |
| Sep 20 - Sep 24 | Buffer, artifact re-mint under neutral slug, submit |
| Post-submit | DeepSeek v4 arm (cost-gated) for the camera-ready / rebuttal window |

## Decision log

- 2026-07-15: plan drafted. OPEN: E4b ECP5 feasibility unverified.
- 2026-07-15 (author): V0 provenance will be disclosed plainly as
  LLM-drafted from a human-written spec, gate-validated, frozen (W5).
- 2026-07-15 (author): venue = ICLR 2027; slip target ICML 2027.
- 2026-07-15 (author): v2 scope adopted: both runtimes (two
  subscription lanes), gpt-5.4/5.5/5.6 focus, deepseek v4 later
  (cost-gated), transfer-score contract metric, scaling curves,
  E5 ablations promoted to P0. Human baseline declined; renewable
  fixtures deferred to v3. Paper rewritten from scratch in paper/v2
  on branch bench-v2.
