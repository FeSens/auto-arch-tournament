# EXP-2026-09-23-gpt6-sol-xhigh-rep1: notes

No prereg.yaml. This run was launched ad hoc, both to measure GPT-6 Sol at xhigh and to exercise the hardened harness (`fix/eval-hardening`) under a live Codex agent. Nothing was written before the run, so none is backdated here. It follows the standard field config (N=15, K=3) at J=1, not the pre-registered J=3.

## Result (measured)

Command (reproduce; from a checkout of `fix/eval-hardening`, `M` = main checkout):
`python3 -m tools.bench.runner --models $M/tools/bench/models-gpt6-sol-xhigh.yaml --ref fix/eval-hardening --reps 1 --n 15 --k 3 --parallel 1 --keep-clones --results-dir $M/bench --results-jsonl $M/bench/results.jsonl --clone-base $M/.claude/bench-runs`
Harness: `1b56891` (fixture = runner, clean). Codex CLI 0.156.1, `gpt-6-sol`, effort xhigh, ChatGPT OAuth. Scored launch 2026-09-23T15:29:57Z, wall 23,546 s.

- Final champion fitness 435.24 (n=1, no dispersion computable). delta_pct +53.89 vs baseline 282.82.
- Candidates: 5 improvements, 40 regressions, 0 broken (45 total). Gate pass rate 45/45.
- Improvements at rounds 1, 2, 4, 6, 14. There were none in rounds 7 to 13 (21 candidates).
- Regression fitness range 189.79 to 401.26.
- Final design: LUT4 5713, FF 2209, Fmax seeds 174.52 / 188.61 / 190.62 (median 188.61), 4,333,465 cycles / 10 iterations.
- Tokens: 32.53M in, 0.59M out. Dollar cost is not measurable through OAuth (the 0.0 is a parser default).
- Artifacts: `bench/gpt-6-sol_xhigh/rep1/`, the `bench/results.jsonl` row with `model=gpt-6-sol_xhigh`, and local clone `.claude/bench-runs/gpt-6-sol_xhigh-rep1` (kept).

## Comparison

None made. n=1, so any comparison against other configurations is `untested` (gate 3). A comparison with the earlier Codex reps is also non-attributable (gate 4): besides the model, the harness changed agent isolation. Published results, research notes and memories are hidden, and there is no login shell.

## Scope & limitations

- One repetition. The r6s0 champion was measured on a single set of seeds, and later candidates within 2 to 4% of it (for example 401.26, 399.13, 398.68) were rejected. With n=1 and no seed replication, it cannot be said whether those rejections reflect design differences or placement variance. Label: untested.
- Round 4's scribe read one file from a Claude Code session's temp directory under `/private/tmp`, found by searching `/private/tmp` for a fitness value. The file held only this run's own monitor events (information the scribe already had in the clone), so no cross-run or future information entered the run. Codex's workspace-write sandbox allows reads anywhere and writes to `/tmp`. A round 7 implementer wrote `/private/tmp/bench_hyp_r7/` (its own synth and place-and-route scratch), and the round 15 scribe later found that directory by searching `/private/tmp`. Evidence: `.codex-home/sessions/**` in the local clone. Within one rep this is information the rep already had. With `--parallel` reps it would be a cross-rep channel.
- How this could be fooling us: Codex runs have no measured dollar cost, and scribe transcripts are not collected into `agent.log`. The token total therefore may not cover every agent call. This is unverified either way.
- Does NOT yet support: any statement about GPT-6 Sol's rank among models, or its variance across reps.

## Decision

keep (publish as a labelled N=1 row). Next step: reps 2 and 3. Open question for the operator: if the nextpnr timeout and `/tmp` isolation fixes (diary 2026-09-23) land first, reps 2 and 3 would run on a different harness commit from rep 1. Either rep 1 is rerun on that commit, or the harness difference is recorded alongside the three reps.
