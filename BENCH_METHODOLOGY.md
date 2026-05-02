# LLM Hardware-Development Benchmark — Methodology

This document describes the benchmark that runs on top of the
auto-arch-tournament harness. It is the methodological reference for
the NeurIPS 2026 submission of the same name.

## What the benchmark measures

How well a coding agent can *iteratively improve a real hardware
design under a verified-correctness gate*. Each agent run is a
multi-round tournament: the agent proposes a microarchitectural
hypothesis, implements it as SystemVerilog edits in an isolated
worktree, and the harness scores the result by passing it through
synthesis lint, formal verification (riscv-formal at NRET=2),
Verilator cosim against a Python ISS, and 3-seed FPGA
place-and-route. A hypothesis is *accepted* only if its fitness on
CoreMark iter/s strictly improves over the current champion.

Distinct from typical LLM coding benchmarks:

- **Long horizon.** Default config is N=15 rounds × K=3 parallel
  hypothesis slots = 45 hypothesis-implement-eval cycles per agent.
  Tests sustained progress, not single-shot generation.
- **Real correctness gate.** riscv-formal on RV32IM at NRET=2 plus
  Verilator cosim — wrong RTL is rejected even if it compiles.
- **Real metric.** CoreMark iter/sec on a Tang Nano 20K via
  yosys + nextpnr-himbaechel — same toolchain a real designer ships
  to.
- **Real architectural search space.** 5 hypothesis categories
  (`micro_opt` / `structural` / `extension` / `predictor` /
  `memory`) covering the actual axes of CPU design.

## Fixed configuration (pre-registered)

The bench is invoked as
`python -m tools.bench.runner --models <yaml> --reps J --n N --k K`
with these fixed values for the NeurIPS run:

| parameter | value | source |
|---|---|---|
| Tournament rounds (N) | 15 | runner CLI `--n 15` (default) |
| Hypotheses per round (K) | 3 | runner CLI `--k 3` (default) |
| Reps per (model, provider) (J) | 3 | runner CLI `--reps 3` (default) |
| Reasoning effort | xhigh | `_runtime.py` (codex `model_reasoning_effort`, opencode `--variant xhigh`) |
| Per-rep wall-clock cap | none | `runner.py` `DEFAULT_REP_TIMEOUT_SEC=0` |
| Per-rep cost cap | $200 | `runner.py` `DEFAULT_MAX_COST_USD=200.0` |
| nextpnr seeds | [1, 2, 3] | `tools/eval/fpga.py` `SEEDS` |
| nextpnr min successful seeds | 2 | `tools/eval/fpga.py` `MIN_SUCCESSFUL_SEEDS` |
| Implementation agent timeout | 30 min | `tools/agents/implement.py` `CLAUDE_TIMEOUT_SEC` |
| Hypothesis agent timeout | 20 min | `tools/agents/hypothesis.py` `HYPOTHESIS_TIMEOUT_SEC` |
| Formal mode | ALTOPS for the loop, full M-extension via `make formal-deep` | `formal/checks.cfg` |

## Fitness formula

```
fitness = fmax_median × iter_per_cycle × 1_000_000   # CoreMark iter/sec
```

(`tools/eval/fpga.py:247`.) `fmax_median` is the median of three
nextpnr placements at seeds 1, 2, 3 (deterministic given the same
input, since nextpnr is seed-determined). `iter_per_cycle` comes
from running CoreMark on the worktree's Verilator binary with
`--bench --istall --dstall` (matches what we'd see on real hardware
with random imem/dmem backpressure).

## Accept rule

A hypothesis is accepted iff its fitness strictly exceeds the
current champion's. (`tools/accept_rule.py`.) When `--coremark-target`
or `--lut-target` are passed, a Pareto-style two-axis score replaces
the scalar comparison; for the standard NeurIPS configuration
neither flag is set, so the rule reduces to "higher CoreMark wins".

## Per-iteration outcomes

Each of the N×K slots produces one of:

- `improvement` — the slot's fitness strictly exceeded the
  pre-round champion. Merged into the active branch (the new
  champion). One per round at most.
- `regression` — passed all eval gates (lint + formal + cosim +
  fpga) but fitness ≤ current champion. Worktree discarded.
- `broken` — failed at one of the eval gates. Subdivided by error
  class for the report:
  - `formal_failed` — riscv-formal counterexample, or
    `no_checks_generated` (RVFI channel-0 retirement contract
    broken).
  - `cosim_failed` — Verilator vs Python ISS divergence on
    `selftest.elf` or `coremark.elf`.
  - `hypothesis_gen_failed` — agent didn't produce a valid
    hypothesis YAML (schema, sandbox violation, off-limits write).
  - `build_failed` — yosys/synth or verilator-build error.
  - `implementation_compile_failed` — RTL doesn't lint.
  - `placement_failed` — fewer than 2/3 nextpnr seeds completed.

## Model lineup

`tools/bench/models.yaml` (frontier, 11 models, all routed via
opencode for uniform tool surface):

| name | runtime | model | provider |
|---|---|---|---|
| opus-47 | opencode | `anthropic/claude-opus-4-7` | Anthropic API |
| sonnet-46 | opencode | `anthropic/claude-sonnet-4-6` | Anthropic API |
| gpt-5 | opencode | `openai/gpt-5` | OpenAI API |
| gpt-5-mini | opencode | `openai/gpt-5-mini` | OpenAI API |
| gemini-3-pro | opencode | `google/gemini-3-pro` | Google API |
| grok-5 | opencode | `xai/grok-5` | xAI API |
| qwen3-coder | opencode | `openrouter/qwen/qwen3-coder` | OpenRouter |
| deepseek-v4 | opencode | `openrouter/deepseek/deepseek-v4` | OpenRouter |
| kimi-k2 | opencode | `openrouter/moonshotai/kimi-k2` | OpenRouter |
| glm-4-6 | opencode | `openrouter/zhipu/glm-4-6` | OpenRouter |
| minimax-m2 | opencode | `openrouter/minimax/m2` | OpenRouter |

`tools/bench/models-codex.yaml` (codex-CLI reference, 3 models —
codex CLI is OpenAI's first-party agent, included as a
control-for-RL-training-fit comparison against the same models via
opencode).

`tools/bench/models-static.yaml` (no-LLM control, see below).

## No-LLM static control

`tools/agents/static_agent.py` is a deterministic placeholder agent.
For each slot it writes a schema-valid hypothesis YAML titled
`"static-control-noop"` with no real RTL changes proposed, and the
implementation phase makes no edits. The eval gates run against
the unchanged fixture — every slot ends up with delta_pct ≈ 0%
(modulo nextpnr-seed measurement variance, which the pinned seeds
[1,2,3] keep at exactly 0%).

Run alongside any LLM bench at the same N×K and J. Any LLM agent's
measured fitness gain *above* the static control's 0% delta is real
signal; an LLM agent that doesn't statistically distinguish itself
from the static control on a given metric isn't contributing on
that metric.

## Statistical comparison

`tools/bench/report.py` renders LEADERBOARD.md with two sections:

1. **Per-model aggregates** — fitness mean ± std across J reps,
   best-of-J, mean iters→best, pass rate, total cost, mean
   wall-clock per iteration.

2. **Paired vs static control** — each model paired with the
   `static` model on shared rep indices, with a two-sided Wilcoxon
   signed-rank test (normal approximation with continuity
   correction, zeros excluded per convention) on `best_fitness`
   differences. n<5 reports `—` for p (the null distribution is too
   sparse for a meaningful p-value at that size); the table still
   surfaces n_pairs, mean Δ, median Δ, W, and treatment_wins so the
   reader can judge effect size.

Pure-python implementation, no scipy dependency.

## Reliability gates and known caveats

The harness has two layers of defense against bench-specific bugs
silently corrupting results:

1. **Per-clone tag deletion** (`runner.py` `clone_fixture`). The
   parent repo carries both a `bench-fixture-v1` *branch* and a
   *tag*; without `git tag -d` post-clone the ambiguous ref causes
   `git checkout bench-fixture-v1` inside `accept_worktree` to
   silently rewind HEAD to the original fixture commit, orphaning
   every prior log entry. Documented as commit `7b58f05`.
2. **Log reconstruction from git history**
   (`runner.py:reconstruct_log_from_git`). Each `append_log` writes
   one entry and immediately `git commit`s it as
   `log: <hyp-id> <outcome>`. The runner walks `git log --all
   --reflog` for these commits and reconstructs the full log
   independently of the on-disk file. If any future bug causes
   log.jsonl to lose entries, the git history (append-only)
   recovers them.

## Reproducibility recipe

```sh
# Clone and check out the frozen bench fixture
git clone <repo> auto-arch-tournament
cd auto-arch-tournament
git checkout bench-fixture-v1

# Install OSS CAD Suite (yosys + nextpnr + sby + verilator) into
# .toolchain/ — see setup.sh.
bash setup.sh

# Authenticate with each provider you'll bench. Codex uses
# ChatGPT subscription OAuth (`codex login`); opencode uses its own
# auth (`opencode providers login`); claude uses `claude` (Anthropic
# OAuth). For paid-API entries put keys in ~/.bench-keys.env.

# Run J=3 reps of the 11-model frontier:
python -m tools.bench.runner \
  --models tools/bench/models.yaml \
  --reps 3 --n 10 --k 3 \
  --keep-clones \
  --results-dir bench/results

# Run J=3 reps of the static control alongside:
python -m tools.bench.runner \
  --models tools/bench/models-static.yaml \
  --reps 3 --n 10 --k 3 \
  --keep-clones \
  --results-jsonl bench/results/results.jsonl  # same JSONL, separate rows

# Render the leaderboard + paired-Wilcoxon comparison vs static:
python -m tools.bench.report \
  --results bench/results/results.jsonl \
  --out bench/results

# Total wall-clock at xhigh on premium models: ~4-5h per rep × 11
# models × 3 reps + control ≈ 130-170h serial, less with --parallel.
```

## What's deliberately out of scope (v1)

- **Multi-LLM-seed.** Same model + same prompt at different LLM seeds
  to disentangle model capability from sampling lottery. Future work.
- **Multi-core architectures.** Adding a wider (64-bit) and a
  narrower (1-issue minimum-area) core to test strategy
  generalization. Future work.
- **Pareto plots** of the IPC vs Fmax tradeoff frontier. Future work.

## Repository state at submission

Branch: `bench-fixture-v1`. Frozen tip is the commit immediately
before this README was added; subsequent commits are post-submission
maintenance only.
