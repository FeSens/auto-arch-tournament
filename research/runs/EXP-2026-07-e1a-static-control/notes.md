# EXP-2026-07-e1a-static-control: notes

## Result (measured)

Two runs on production bench/results.jsonl:
- rep1 (2026-07-16, ref bench-v2 = cf2be5b): status=done, delta_pct 0.0,
  46 rows = 1 accepted + 3 regressions + 42 broken
  (hypothesis_gen_failed). INCIDENT per prereg success rule; kept as
  incident datum. See research/diary/2026-07-16.md.
- rep2 (2026-07-16, ref bench-v2 = 6f898db, after the shared-parser fix):
  status=done, wall 7262s, delta_pct = 0.0 exactly, final = baseline =
  282.82, 46 rows = 1 accepted (baseline retest) + 45 regressions +
  0 broken. Canonical tuple 9563 LUT4 / 1866 FF / 127.03 MHz reproduced.

Reproduce:
`python3 -m tools.bench.runner --models tools/bench/models-static.yaml --reps 2 --n 15 --k 3 --ref bench-v2`

## Verdict

Gate PASSED on rep2 per the prereg success rule (any nonzero delta or
broken row = harness bug). E1/E2 data collection unblocked. Determinism
corroboration: burn-in static pair 3/3 delta=0.0 (2026-07-15) plus this
full-length production rep.

## Decision

keep (rep2 gate datum; rep1 incident datum, never deleted).
