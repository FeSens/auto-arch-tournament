# EXP-2026-07-e1b-random-control: notes

## Result (measured)

Command (reproduce):
`python3 -m tools.bench.runner --models tools/bench/models-random.yaml --reps 3 --parallel 2 --n 15 --k 3 --ref bench-v2`
(ref bench-v2 = 6f898db; seeds 101/102/103 injected per rep by the runner;
run of 2026-07-16, launched 15:02:11Z after a first launch at 14:55:20Z was
killed ~4 min in by an external cause before writing anything).

- Final champion fitness: 282.82 +/- 0.0 (n=3 reps; zero dispersion,
  champion never moved in any rep). delta_pct = 0.0 exactly, every rep.
- Accepted strict improvements: 0 of 45 mutation slots per rep (0/135
  overall). The single "accepted" row per rep is the baseline retest.
- first_failing_gate_distribution: formal_failed 135/135 (100%).
  gate_pass_rate: 0/135. No mutation ever reached cosim or FPGA eval.
- Infra health: zero hypothesis_gen_failed, zero infra failures
  (the 2026-07-15 parser fix held for the random agent in production).
- Wall: rep1 1612s, rep3 1595s (solo lane), rep2 3448s (overlapped both
  other reps in dual-lane; contention only, not a metric).

## Comparison

Prereg hypothesis ("accepts ~0 strict improvements; any accepted
cumulative delta < 5%"): observed 0 accepted and delta exactly 0.0,
consistent with the hypothesis. The success_rule's comparison against
LLM configs is an analysis-stage step; the E1b-side precondition
(mean accepted-count < 1) is met with mean 0.

## Scope & limitations

- Operator set is the preregistered parse-safe subset (op_swap,
  ternary_swap, lit_perturb; k~U{1,2,3}; lint-guided redraw max 20).
  "Random mutation" here means lint-clean few-token semantic
  perturbations of working RTL. This does NOT bound what a stronger
  mutation engine (e.g. AST-aware or eval-guided) could pass; the claim
  is scoped to this operator set.
- How this could fool us: if the lint redraw loop had silently produced
  no-op mutations, formal would PASS (a no-op is the baseline, which
  passes), producing regressions, not formal_failed rows. The observed
  100% formal_failed distribution is evidence the mutations were real
  semantic changes, not no-ops.
- Telemetry gap: lint_draws_used (prereg secondary metric) is not
  recoverable from the published artifacts: draw counts live in
  implementation_notes.md (gitignored by contract) inside the per-rep
  clones, which are removed at rep end. Recomputable offline by
  replaying the seeded draws (deterministic, no evals needed) if the
  paper needs it.

## Decision

keep. Next step: E1c naive-prompt control per its prereg.
