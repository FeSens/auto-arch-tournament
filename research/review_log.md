# Review log

## MLCAD 2026, submission 48 (rejected 2026-07)

Title: "HWE Bench: An Unbounded Benchmark for LLM Hardware Engineering"
Outcome: reject. 175 valid submissions, 37 regular + 14 short accepted
(21.1% regular, 29.1% overall). Scores: 0 / 0 / -2.

Paper as reviewed: `paper/main.tex` at the MLCAD submission state
(17-run, 6-configuration snapshot; V0 283 iter/s; best run 525 iter/s).

### Reviewer 1 (score 0, borderline)

- R1.a Positive: gate chain (Verilator lint, Yosys, riscv-formal, ISS
  cosim, CoreMark validation, FPGA P&R) is a strength.
- R1.b Limited benchmark scope: one starting core, one FPGA target, one
  CAD flow, CoreMark as the only workload.
- R1.c V0 origin not stated: authored? derived from an open core?
  intentionally simplified? already optimized?
- R1.d Sample size: 2-3 reps per config, overlapping std devs, cannot
  support ranking among configurations.
- R1.e Tone: "We ask a direct question", "HWE Bench is that setup",
  "the gate is doing its job", "broken silicon" flagged as informal or
  promotional.

### Reviewer 2 (score 0, borderline)

- R2.a Positive: correctness-as-gate design, ALTOPS disclosure and
  mitigation, scaffolding contribution, honest Section 6, auditable
  artifact with row-count reconciliation.
- R2.b Missing random-edit control: cannot distinguish agent reasoning
  from "gates + repeated sampling"; the "LLM-Driven Hardware
  Optimization" framing is only weakly supported. Named the central gap.
- R2.c Thin reps; the headline 525 iter/s is a best-of-run upper-tail
  statistic reported prominently in the abstract.
- R2.d Narrow baseline: one external reference (VexRiscv, strongest
  published config) and one in-flow core (V0).
- R2.e Workload overfitting: replay predictor flagged CoreMark-specific
  by the authors; unclear how much of the other 72 accepted edits is
  workload-tuned versus genuine QoR gain.
- R2.f Security caveat requested: RVFI proofs are functional
  correctness only; accepted optimizations (divider rewrite, replay
  predictor) not checked for new timing variance.

### Reviewer 3 (score -2, reject)

- R3.a Scope very narrow (RV32IM, one FPGA setup); no ablation studies.
- R3.b Agent scope unclear: what does the agent observe (only logs and
  final metrics?), do agents learn by themselves, what is the action
  space.
- R3.c Search is greedy by construction; exploration too restricted.
- R3.d Writing repetitive and inflated, "probably due to LLM writing";
  Section 2.1 should be part of the method.

### Cross-reviewer consensus

1. Attribution control (R2.b, implicitly R3): the decisive missing
   experiment, and the paper itself names it.
2. Sample size and best-of-run framing (R1.d, R2.c).
3. Scope: workloads, baselines, targets (R1.b, R2.d, R2.e, R3.a).
4. Method transparency: V0 provenance, agent observability and action
   space (R1.c, R3.b).
5. Writing: tone, repetition, structure (R1.e, R3.d).

Point-by-point disposition lives in
`research/paper_revision_plan.md` (same commit).
