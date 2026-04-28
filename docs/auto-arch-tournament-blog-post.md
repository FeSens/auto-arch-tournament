# Auto-Architecture: Karpathy's Loop, Pointed at a CPU

What happens when you take an autonomous research loop out of its comfort zone and aim it at a domain it has no business being good at? Andrej Karpathy's [autoresearch](https://github.com/karpathy/autoresearch) showed that a coding agent, given two days and a single-GPU nanochat, finds 20 training-time optimizations on its own. The recipe is general — propose, implement, measure, keep the wins — but the demonstration was inside the agent's home turf: Python, gradient descent, well-known knobs.

I wanted to know if it generalized. So I pointed it at a CPU.

![Side-by-side pipeline diagram of the V0 baseline (5-stage IF/ID/EX/MEM/WB, no predictors, no replay) and the post-tournament champion, with each accepted component highlighted: instruction-replay table + static branch/JAL prediction in IF, hot/cold ALU split and cold iterative DIV/REM in EX, a pending-store retirement slot off MEM, and an NRET=2 RVFI port set with channel 1 tied off. Bottom banner: +91.9% CoreMark vs baseline.](blueprints/pipeline-vs-baseline-image-model.png)

## The setup

[`auto-arch-tournament`](.) is a 5-stage in-order RV32IM core in SystemVerilog — the textbook pipeline you'd write in a graduate architecture class. No caches, no branch predictor, no multi-issue on day one. Those are research-loop hypotheses, not features.

The orchestrator is hardcoded. The LLM never edits it. Each round, three slots run in parallel:

1. The agent proposes a microarchitectural hypothesis as YAML, schema-checked against `schemas/hypothesis.schema.json`.
2. An implementation agent edits files under `rtl/` in an isolated git worktree.
3. The eval gate runs:
   - **riscv-formal** — 53 symbolic BMC checks (decode, traps, ordering, liveness, M-ext)
   - **Verilator cosim** — RVFI byte-identical against a Python ISS, ~22% random bus stalls
   - **3-seed nextpnr P&R** on a Gowin GW2A-LV18 (Tang Nano 20K) — median Fmax × CoreMark iter/cycle = fitness
   - **CoreMark CRC validation** — the same 4 CRCs VexRiscv reports against
4. Improvement → merged into the trunk, becomes the new baseline. Regression / broken / placement-failed → worktree destroyed.

A diversity rotation forces each slot to pick a different category (`micro_opt | structural | predictor | memory | extension`) so the agent doesn't fixate on one idea.

## Show me the results

Baseline locked at the same methodology VexRiscv publishes — full no cache, 2K data, `-O3`, ~22% bus backpressure — at **2.23 CoreMark/MHz, 301 iter/s**. The human benchmark is VexRiscv's published 2.57 CoreMark/MHz @ 144 MHz.

Then I let it run. **73 hypotheses, 9h 51m wall-clock.**

| Outcome                | Count |
|------------------------|-------|
| Improvement (accepted) | 10    |
| Regression             | 50    |
| Broken (formal/cosim)  | 9     |
| Placement failed       | 4     |

The 10 accepted winners, in order:

| Δt    | iter/s | CM/MHz | Fmax    | LUT4   | Hypothesis                                    |
|-------|--------|--------|---------|--------|-----------------------------------------------|
| 0.0h  | 301.04 | 2.226  | 135 MHz | 9,880  | Baseline                                      |
| 0.4h  | 313.10 | 2.320  | 135 MHz | 10,186 | Backward-Branch Taken Predictor               |
| 0.7h  | 324.48 | 2.348  | 138 MHz | 10,192 | IF Direct-Jump Predictor                      |
| 2.1h  | 375.43 | 2.348  | 160 MHz | 5,888  | Cold Multi-Cycle DIV/REM Unit                 |
| 2.7h  | 397.55 | 2.366  | 168 MHz | 5,854  | One-Deep Store Retirement Slot                |
| 3.5h  | 422.77 | 2.366  | 179 MHz | 5,933  | Segmented RVFI Order Counter                  |
| 3.8h  | 472.96 | 2.891  | 164 MHz | 5,916  | Registered Lookahead I-Fetch Replay Predictor |
| 4.0h  | 505.65 | 2.891  | 175 MHz | 5,938  | Compressed Resetless I-Fetch Replay Tags      |
| 5.3h  | 529.35 | 2.891  | 183 MHz | 5,930  | RTL-Only Hot/Cold ALU Opcode Split            |
| 6.1h  | 577.76 | 2.908  | 199 MHz | 5,944  | Banked Registered I-Fetch Replay Predictor    |

End state: **2.91 CoreMark/MHz, 577 iter/s, 199 MHz Fmax, 5,944 LUT4**.

That is **+92% over the locked baseline and +56% over VexRiscv on CoreMark iter/sec (370 → 578), with 40% fewer LUTs**. The win compounds: ~13% of it is architectural efficiency (2.91 vs 2.57 CoreMark/MHz) and the rest is Fmax (199 vs 144 MHz) — a smaller, simpler design that the synthesizer also clocks faster. For context, the CoreMark/MHz gap between VexRiscv's `full no cache` and `linux balanced` configs (their next tier up, with caches) is about 40 percentage points — so the loop closed 13 of those in under ten hours, on a single FPGA target, against a baseline VexRiscv took years to reach.

![CoreMark progress: green dots are accepted winners (the black step-line walks through them), orange are rejected, red dashed line is the VexRiscv-comparable fitness on this FPGA, gray dotted line is the locked baseline.](../experiments/progress.png)

The black step-function is the running best. It crosses the human-tuned VexRiscv line at iteration 6 and never looks back. The interesting move was iteration 3 — pulling DIV/REM out of the single-cycle path. The agent did not know that would also halve the LUT count. It found out by doing it and watching the synthesizer.

## The interesting part is not the loop

There is a lot of noise right now about agent loops. Build a planner, build a coder, give them tools, run them in a swarm, raise a seed round. The loop is mostly a solved problem. Pick a model, pick a scaffolding library, pick how many parallel slots you can afford. Whatever moat you think you have on the loop, you have it for six months.

The thing nobody is paid to build, and the thing this project is actually about, is the verifier.

Of 73 hypotheses, **63 were wrong**. They regressed, broke the ISA, or failed timing. Some real examples from the log:

- **The same idea, twice.** `Move DIV/REM off the single-cycle ALU path` first came in at round 1, slot 0, and broke cosim on the selftest before it ever got to the FPGA. The agent rephrased it as `Cold Multi-Cycle DIV/REM Unit` two hours later — same idea, fixed implementation — and it became the breakthrough win. Without the cosim gate the broken first attempt would have shipped.
- **Sandbox violations.** Two separate hypotheses tried to add a `test/_helpers.py` file outside the `rtl/**` and `test/test_*.py` allowlist. The path sandbox rejected the round before any eval ran. If you let the agent edit the harness, eventually it will edit the harness.
- **A regression of −73%.** At round 24, after the peak fitness of 577 iter/s was already locked, the agent proposed `Registered Lookahead JALR Target Predictor`. Fitness collapsed to 154 iter/s — a 73% drop. Accepted into trunk, that one mistake undoes every previous win in a single round. The orchestrator caught it on the comparison-against-baseline check.
- **Schema errors.** One hypothesis declared `fitness_delta_pct: 1.5` where the schema requires an integer. Rejected before any code was generated. Trivial — and exactly the kind of thing that, without the schema, becomes a silent type coercion later in the pipeline.

Each of those failures cost ~5–15 minutes of compute. Each of them, ungated, would have either corrupted the run or taught the agent that a wrong move was a right one.

The verifier in this project does the unglamorous things you'd be tempted to skip:

- The `ill / unique / liveness / cover` formal checks, not just the `insn_*` ones. The first four catch silently-broken cores; the `insn_*` ones only catch silently-broken arithmetic.
- A path sandbox. The agent can edit `rtl/**` and `test/test_*.py`. Touch `formal/checks.cfg`, `tools/eval/fpga.py`, or the canonical CRC table and the round is rejected before any eval runs. Otherwise an agent will eventually "improve" by softening a check.
- 3-seed P&R, median Fmax. One seed is a coin flip; three is a number you can compare across iterations.
- CRC validation on the bench output. CoreMark prints `Correct operation validated.` even when it isn't, because it checks its own CRCs and prints the literal regardless. The eval re-validates the four CRCs against the canonical 2K-config values.
- Bracketing the timed region with MMIO start/stop markers. CoreMark's warm-up and printf will eat your fitness number if you measure end-to-end.

The agent loop is a producer. The verifier is the only thing standing between you and a confidently-wrong number.

## What this means for the next batch of companies

The next wave of companies is not going to be people writing code. It's going to be people writing verifiers, with a loop running against them.

The loop is commodity. Model + prompt + tools + scoreboard + parallel slots. Everyone is converging on the same shape, and the providers of those pieces are racing each other to zero margin.

The verifier is not commodity. It is the artifact that encodes what your business actually means by *correct*. In a CPU it's an ISA and a formal property suite. In a billing pipeline it's invariants on a ledger. In a compiler it's a differential test against the reference. In a clinical workflow it's a property the FDA has signed off on. None of these are AI problems. They are "what is your domain, and can you write the rules down" problems.

If you can write the rules down, an agent will satisfy them faster than your team will. If you can't — and most teams can't, because the rules live in three engineers' heads and a Confluence page nobody updated — the agent will satisfy a *different* set of rules, the ones it inferred from what it could observe. You will not notice until production.

The companies that win this aren't the ones with the smartest planner. They're the ones whose verifier is the contract.

## What is next

The project is currently sequential at the round level — losers are discarded each round even though their failed paths are useful signal. The next iteration moves to a population-based search: keep the top-K every round, mutate from any of them, let dead-end branches stay dead. That should scale the search space without scaling the model bill linearly.

I'm also curious how much of the win in the first 10 hours generalizes off CoreMark. Some of those predictors clearly overfit to its branch profile. Next experiment swaps in Embench against the same baseline, and we see which winners survive a workload change and which were CoreMark trivia.

Both are interesting questions. The more interesting question — for me, and for anyone shipping a product — is which parts of your business already have a verifier sharp enough to point a loop at. Find that, and your team's productivity stops scaling with headcount.

The future is bright. The frontier is the verifier.