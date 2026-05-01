# N=10 K=3 gpt-5.5 — codex vs opencode (xhigh, bench agent for opencode)

Both runtimes pinned to `xhigh` reasoning effort. Opencode runs the
custom `bench` agent (verification-discipline prompt, RVFI specifics
omitted). Codex runs its native CLI agent. Same starting fixture
(bench-fixture-v1), same orchestrator code, parallel reps.

## Per-rep totals

| field | codex-gpt-5_5 | opencode-gpt-5_5 |
|---|---|---|
| iterations (visible in saved log.jsonl) | 6 | 18 |
| accepted | 1 | 1 |
| broken | 2 | 4 |
| regressed | 3 | 13 |
| broken rate | 33% | 22% |
| best_fitness | **384.26** | 359.97 |
| best_round | 1 (within saved window) | 1 (within saved window) |
| baseline_fitness | not parsed | not parsed |
| delta_pct | not computed | not computed |
| wall_clock_sec | 16,488 (~4h 35m) | 14,845 (~4h 7m) |
| total_tokens_in | 16,862,581 | 1,257,361 |
| total_tokens_out | 217,039 | 40,786 |
| total_cost_usd | 0.00 (OAuth) | 0.00 (OAuth) |
| token ratio (codex/opencode) | 13.4× input, 5.3× output | — |

**Caveat — log rotation**: the orchestrator's `log.jsonl` rotates
mid-run; the saved per-rep log captures only the final window
(2 rounds for codex, 6 rounds for opencode). The earlier rounds
(including codex's `+10.2%` RAS-predictor and opencode's BTB/BHT
predictor improvements seen on the live monitor) are not in the
artifacts after the rep clones got cleaned up. The
`final_fitness`/`best_fitness` values *are* cumulative across the
full run because the orchestrator keeps the champion lineage in git
state, even though their originating slot rows aren't in this file.

`baseline_fitness` is `null` in both rows because no slot's payload
included a `baseline_fitness` field that the summarizer recognized;
delta% over baseline isn't computable from the saved artifacts.

## Codex per-iteration (saved window)

| round | slot | outcome | fitness | hypothesis |
|---|---|---|---|---|
| A | 0 | improvement | 384.26 | Unsigned multiply correction |
| A | 1 | regression | 270.36 | Reuse ALU JALR target sum |
| A | 2 | broken | — | Counted RAS return predictor |
| B | 0 | broken | — | Filter false load-use stalls |
| B | 1 | regression | 270.34 | Decoupled fetch queue |
| B | 2 | regression | 321.99 | Static backward branch predictor |

## Opencode per-iteration (saved window)

| round | slot | outcome | fitness | hypothesis |
|---|---|---|---|---|
| A | 0 | improvement | 359.97 | Drop regfile reset for LUTRAM |
| A | 1 | broken | — | Iterative divider off ALU |
| A | 2 | regression | 298.59 | ID-stage JAL target predictor |
| B | 0 | regression | 296.69 | Mask false load-use stalls |
| B | 1 | broken | — | Add frontend prefetch FIFO |
| B | 2 | regression | 183.25 | Tiny EX-trained branch target predictor |
| C | 0 | regression | 332.50 | Share M-extension multiplier |
| C | 1 | regression | 332.50 | Share multiplier datapath |
| C | 2 | regression | 288.58 | Return-address stack predictor |
| D | 0 | regression | 320.03 | Slim late pipeline control |
| D | 1 | regression | 326.31 | Retiming redirect target adders |
| D | 2 | regression | 210.28 | Registered one-entry loop predictor |
| E | 0 | regression | 300.39 | Case-based load extraction |
| E | 1 | regression | 300.31 | One-entry RAM store buffer |
| E | 2 | broken | — | Static hot-loop PC predictor |
| F | 0 | broken | — | Valid-only pipeline resets |
| F | 1 | regression | 350.76 | Slow rare-M sidecar |
| F | 2 | regression | 260.93 | Late BTFNT branch redirect |

## Broken slots — error condensation

**codex (2):**
- A.s2 *Counted RAS return predictor* — `formal_failed: reg_ch0` (RVFI channel-0 contract on writeback path)
- B.s0 *Filter false load-use stalls* — `cosim_failed: selftest.elf` (functional behavior diverged from Python ISS)

**opencode (4):**
- A.s1 *Iterative divider off ALU* — `cosim_failed: selftest.elf` (M-extension arithmetic incorrect)
- B.s1 *Add frontend prefetch FIFO* — `formal_failed: no_checks_generated` (RVFI ch0 broken by IF-stage restructuring)
- E.s2 *Static hot-loop PC predictor* — `formal_failed: no_checks_generated` (RVFI ch0 broken by front-end change)
- F.s0 *Valid-only pipeline resets* — `cosim_failed: coremark.elf` (control flow diverged on CoreMark)

## Notable patterns

- **RVFI ch0 breaks concentrate on front-end / fetch / predictor restructuring.** Three of opencode's four broken slots fit this pattern (prefetch FIFO, hot-loop PC predictor, valid-only resets propagating into IF), and codex's RAS-predictor break in window A.s2 fits it too. The dropped RVFI specifics in the rewritten public-prose bench agent track this gap as predicted.
- **Cosim breaks concentrate on M-extension or load/store path rewrites.** Iterative divider (opencode), Filter false load-use stalls (codex), Valid-only pipeline resets (opencode) — all change behavior the Python ISS catches against ALTOPS-formal-passing RTL.
- **Codex consumes 13× more input tokens than opencode** (16.9M vs 1.26M) at the same xhigh effort. The verification-discipline gap from codex's first-party RL training shows up as more shell calls and more grep cycles, not just deeper reasoning per turn.
- **Codex still wins the fitness race** (384.26 vs 359.97 final, ~6.7%) despite both runs picking similar hypothesis families (branch predictors, RAS, multiplier sharing, load-use bypass). Codex's higher reliability on front-end work compounds across rounds.
- **Both runs hit the orchestrator's per-rep wall-clock around 4 hours and stopped before reaching nominal N=10 in saved-log terms** — the underlying cause is log-rotation/iteration accounting in the summarizer, not the runner exiting early.
- **Best fitness in both cases came from a structural micro-architecture change rather than a more ambitious pipeline restructuring.** Codex's lineage settles on Unsigned-multiply-correction (latest visible improvement); opencode's settles on regfile-reset removal for LUTRAM. The exotic hypotheses (elastic fetch queues, BTB/BHT predictors layered on top of existing predictors, etc.) regressed or broke in both runs.
