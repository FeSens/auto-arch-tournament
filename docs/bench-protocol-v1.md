# bench-protocol-v1

**Status:** frozen  
**Applies to:** `bench-fixture-v1` dataset tag  
**Date frozen:** 2026-04-30

---

## 1. Versioning

This document freezes the v1 protocol. Future versions will increment and append a per-version section. The protocol is the contract under which `bench-fixture-v1` results are reported.

A result row is only admissible under this protocol when:

- The fixture was cloned from the `bench-fixture-v1` git ref.
- The runner flags matched the defaults documented in §5, or deviations are explicitly declared in the paper's supplement.
- The bench-fence allowlists (§4) were in effect — attested by the sha256 hashes in §10.

---

## 2. Agent runtimes

The runner supports four providers, selected per-model via the `provider` field in `tools/bench/models.yaml` (default: `pi`):

| Provider key | Binary invoked | Notes |
|---|---|---|
| `pi` | `pi` | pi-coding-agent; default for most models |
| `codex` | `codex` | OpenAI Codex CLI; built-in workspace-write sandbox |
| `opencode` | `opencode` | opencode agent |
| `claude` | `claude` | Claude CLI |

### Tool versions at protocol-freeze time

```
opencode --version   →  (not installed at protocol-freeze time)
codex --version      →  codex-cli 0.125.0
pi --version         →  (not installed at protocol-freeze time)
claude --version     →  1.14.30
```

`opencode` and `pi` were not present in the PATH of the machine where this document was authored. The versions used in the actual benchmark runs (reported in `bench/results.jsonl`) will be captured by the runner's `tool_versions` field (added by the runner-extension agent, Task 16).

### Per-provider invocation flags

**`pi` provider** (derived from `tools/bench/runner.py` `make_env_for_job` and `tools/agents/_runtime.py` `build_agent_cmd`):

```
pi -p <prompt>
   --mode json
   --model <PI_MODEL>
   --tools read,write,edit,bash,grep,find,ls
   [--session-dir <PI_SESSION_DIR>]   # when PI_SESSION_DIR is set
```

Environment variables set by the runner:
- `AGENT_PROVIDER=pi`
- `PI_MODEL=<pi_model string from models.yaml>`
- `PI_SESSION_DIR=<clone>/.pi-sessions`
- `BENCH_FORMAL_AUTOFIX=1`  (not set for codex)

The bench-fence extension is installed into `<clone>/.pi/extensions/bench-fence/` before the `make` invocation; pi auto-loads it from that path.

**`codex` provider**:

```
codex --ask-for-approval never
      exec
      -C <cwd>
      --sandbox workspace-write
      --skip-git-repo-check
      --json
      --output-last-message <path>
      [--model <CODEX_MODEL>]
      <prompt>
```

Environment variables set by the runner:
- `AGENT_PROVIDER=codex`
- `CODEX_MODEL=<pi_model string from models.yaml>`

Codex uses its built-in `workspace-write` sandbox; no bench-fence file is installed (the clone already omits other cores). `BENCH_FORMAL_AUTOFIX` is not set for codex because the Codex CLI is workflow-trained and self-checks naturally.

**`claude` provider**:

```
claude -p <prompt>
       --dangerously-skip-permissions
       --output-format stream-json
       --verbose
       [--model <model>]
```

**`opencode` provider**: invoked as `opencode`; flags TBD in Task 16 runner extension.

---

## 3. Per-model `pi_model` strings

All models registered in `tools/bench/models.yaml` at `bench-fixture-v1`:

| name | pi_model | key_env | oauth | provider |
|---|---|---|---|---|
| opus-47 | anthropic/claude-opus-4-7 | ANTHROPIC_API_KEY | false | pi |
| sonnet-46 | anthropic/claude-sonnet-4-6 | ANTHROPIC_API_KEY | false | pi |
| gpt-5 | openai/gpt-5 | OPENAI_API_KEY | false | pi |
| gpt-5-mini | openai/gpt-5-mini | OPENAI_API_KEY | false | pi |
| gemini-3-pro | google/gemini-3-pro | GOOGLE_API_KEY | false | pi |
| grok-5 | xai/grok-5 | XAI_API_KEY | false | pi |
| qwen3-coder | openrouter/qwen/qwen3-coder | OPENROUTER_API_KEY | false | pi |
| deepseek-v4 | openrouter/deepseek/deepseek-v4 | OPENROUTER_API_KEY | false | pi |
| kimi-k2 | openrouter/moonshotai/kimi-k2 | OPENROUTER_API_KEY | false | pi |
| glm-4-6 | openrouter/zhipu/glm-4-6 | OPENROUTER_API_KEY | false | pi |
| minimax-m2 | openrouter/minimax/m2 | OPENROUTER_API_KEY | false | pi |

Notes from the registry:

- Native provider keys (Anthropic, OpenAI, Google, xAI) bypass the OpenRouter ~5-10% markup. OpenRouter is used for all other models.
- API keys are loaded from `~/.bench-keys.env` (gitignored), one `VAR=value` per line.
- The `pi_model` string is passed verbatim to `pi --model` (for the `pi` provider) or `codex --model` (for the `codex` provider).

---

## 4. bench-fence allowlists

The bench-fence extension enforces path-level isolation for each benchmark run. The allowlists below are the **source of truth** from `tools/bench/fence_validator.py` (`DEFAULT_READ_ALLOW` and `DEFAULT_WRITE_ALLOW`).

### Read allowlist (`DEFAULT_READ_ALLOW`)

- `cores/bench`
- `formal`
- `fpga`
- `bench/programs`
- `test/cosim`
- `tools`
- `schemas`
- `Makefile`
- `CLAUDE.md`
- `ARCHITECTURE.md`
- `README.md`
- `.gitignore`
- `.agent.last`
- `.agent.log`
- `.pi-sessions`
- `.pi/extensions/bench-fence`

The fence also permits reading any **ancestor** of an allowed path (e.g. `ls cores` is allowed because `cores/bench` is in the list) so the agent can navigate, but cannot read `cores/baseline/` or `cores/v1/`.

### Write allowlist (`DEFAULT_WRITE_ALLOW`)

- `cores/bench/rtl`
- `cores/bench/test`
- `cores/bench/experiments`
- `cores/bench/implementation_notes.md`
- `cores/bench/obj_dir`
- `cores/bench/generated`
- `cores/bench/sim_build`
- `formal/work`
- `obj_dir`
- `sim_build`
- `.pi-sessions`
- `.agent.last`
- `.agent.log`

### Bash blocklist (`DEFAULT_BASH_BLOCKLIST`)

The following tokens are blocked in any bash command:

- `cores/baseline`
- `cores/v1`
- `cores/bench-`
- `/baseline/`
- `/v1/`
- `git checkout main`
- `git checkout master`
- `git fetch`
- `git log -p`
- `git log --patch`
- `git show main`
- `git show master`
- `git stash`
- `.git/objects`
- `git reflog`
- `git cat-file`

### Fence file hashes (at `bench-fixture-v1`)

```
sha256(tools/bench/fence_validator.py)           = f434d6acba30b88a817b38533201ee9f623644efa155b0adf593e86f9b77d360
sha256(tools/bench/extensions/bench-fence/index.ts) = f261d77674665462b208a2a4268fe7e9738060f35a85907befb213248a303451
```

These hashes are over the raw file bytes as stored in the `bench-fixture-v1` git object (computed via `git show bench-fixture-v1:<path> | sha256sum`). A reviewer can reproduce them with the same command against the published tag.

---

## 5. Round budget and parallelism

### Default values (from `tools/bench/runner.py`)

| Parameter | Default | Meaning |
|---|---|---|
| `N` | 10 | Orchestrator rounds per rep |
| `K` | 3 | Parallel hypothesis slots per round |
| `reps` | 3 | Repetitions per model (J in the paper) |
| `--timeout-sec` | 32400 (9 h) | Per-rep wall-clock ceiling |
| `--max-cost` | $30.00 USD | Per-rep cost ceiling |
| `--parallel` | 1 | Concurrent (model, rep) jobs |

Total matrix size: `len(models) × reps` = 11 × 3 = 33 (model, rep) jobs by default.

### Retry and resumption policy

- A rep that hits the timeout or cost ceiling, or exits non-zero from `make`, is recorded with `status=failed` in `bench/results.jsonl`.
- The runner is **idempotent on (model, rep) tuples**: on restart it loads the existing `bench/results.jsonl` and skips any pair that already has a final row. This allows resuming a partial run without re-running completed reps.
- There is no automatic retry of individual rounds within a rep; a failed rep counts as one of the J=3 reps for that model.
- The per-rep cost check runs every 60 seconds (not per-tool-call). The actual spend may modestly exceed the ceiling by the cost of the final tool call before the check fires.

### Make invocation

The runner drives the orchestrator via:

```
make N=<N> K=<K> TARGET=bench loop WORKTREE=
```

executed from the per-job clone directory with the provider-specific environment variables in place.

---

## 6. Hypothesis-agent system prompt

The hypothesis agent's prompt is assembled dynamically by `tools/agents/hypothesis.py::_build_prompt`. The template below is the static scaffold; `{current_fitness}`, `{baseline_fitness}`, `{rtl_dir}`, `{arch}`, `{claude_md}`, `{src_dump}`, `{recent_outcomes_str}`, `{target}`, and the optional blocks (`{target_banner}`, `{category_clause}`, `{targets_clause}`, `{philosophy}`, `{core_yaml_block}`) are substituted at call time.

```
You are a CPU microarchitecture research agent.

Your job: propose one architectural hypothesis to improve this RV32IM CPU.
Fitness metric: CoreMark iter/sec = CoreMark iterations/cycle × Fmax_Hz on Tang Nano 20K FPGA.
Current best fitness: {current_fitness:.2f}
Baseline fitness: {baseline_fitness:.2f}

{target_banner}{category_clause}{targets_clause}{philosophy}{core_yaml_block}
## Architecture
{arch}

## Hard invariants (do NOT propose changes that weaken these)
{claude_md}

## Current SystemVerilog Source ({rtl_dir}/)
{src_dump}

## Recent outcomes (last 5)
{recent_outcomes_str}

## Distilled lessons from prior iterations (cores/{target}/LESSONS.md)
{_lessons_block(target)}

## How to dig deeper
- Full per-iteration history is at: cores/{target}/experiments/log.jsonl
  Each line is one experiment: hypothesis prose + fitness numbers + outcome
  + the implementing agent's implementation_notes. Use Read or Grep to dig
  into specific past hypotheses by id, category, outcome, or content.
- LESSONS.md (above) is the curated, append-only log of one-line takeaways.
  Read it before proposing — it captures negative knowledge (what failed
  and why) you would otherwise re-discover.

## Instructions
1. Read LESSONS.md and the recent outcomes above. Grep log.jsonl for
   relevant prior attempts in the same category before proposing.
2. Identify the most promising architectural improvement.
3. Use the **write** tool to write a hypothesis YAML file at:
     cores/{target}/experiments/hypotheses/<id>.yaml
   Do NOT output the YAML as text in your reply — the orchestrator only
   sees files written via the write tool.

{id_clause}

## Required YAML structure (validates against schemas/hypothesis.schema.json)

```yaml
id: hyp-YYYYMMDD-NNN-rRsS         # exactly the ID above
title: "Short description ≥5 chars"
category: micro_opt                # one of: micro_opt | structural | extension | predictor | memory
motivation: |
  Why this matters — a few sentences. Minimum 20 chars.
hypothesis: |
  What you propose to change and why it should help. Minimum 20 chars.
expected_impact:
  fitness_delta_pct: 5             # INTEGER (-50..+50). Schema rejects strings.
  confidence: medium                # exactly one of: low | medium | high. Schema rejects anything else.
changes:                            # at least one entry
  - file: rtl/forward_unit.sv      # IMPORTANT: relative to rtl/, no `cores/<target>/` prefix.
    description: "What you'll change in this file."
  - file: rtl/id_stage.sv          # Or `test/test_<name>.py` for cocotb suites.
    description: "..."
```

### Common mistakes that make schemas reject the file (do NOT do these)

- `expected_impact: "free-text description"` — schema requires an OBJECT with `fitness_delta_pct` (integer) and `confidence` (enum). Strings are rejected.
- `expected_impact: {fitness_delta_pct: 5.0, confidence: "Med"}` — `fitness_delta_pct` must be a Python integer (not float, not "5"); `confidence` must be lowercase `low`/`medium`/`high`.
- `changes[i].file: cores/{target}/rtl/alu.sv` — schema's regex requires the `rtl/...` form. Drop the `cores/<target>/` prefix.
- `changes[i].file: alu.sv` — the regex requires the `rtl/` prefix.
- Writing the YAML inline in your message instead of using the write tool.

Use the write tool now.
```

#### Dynamic clauses

**`{target_banner}`** (injected when `target` is set): Warns the agent which core it is editing (`cores/{target}/`) and specifies that `changes[i].file` must use the short `rtl/<filename>` form.

**`{category_clause}`** (injected when `category_hint` is set): Constrains the hypothesis to a diversity-rotation category — one of `micro_opt`, `structural`, `predictor`, `memory`, `extension`.

**`{targets_clause}`** (injected when `targets` dict is present): Shows the numeric targets (`CoreMark` iter/s and/or `LUT4`) and the current champion values.

**`{philosophy}`**: Contents of `cores/{target}/CORE_PHILOSOPHY.md` if it exists and is non-empty.

**`{core_yaml_block}`**: Contents of `cores/{target}/core.yaml` if it exists.

---

## 7. Implementation-agent system prompt

The implementation agent's prompt and runtime are defined in `tools/agents/_runtime.py`. The agent is invoked by the orchestrator (`tools/orchestrator.py`) to implement a hypothesis YAML. The agent receives the hypothesis YAML and the current state of `cores/bench/rtl/` via the standard `build_agent_cmd` interface.

The `_runtime.py` module does not define a static system-prompt string; instead the prompt is assembled by the caller (`implement.py`) and passed as the first positional argument to the agent CLI. The runtime-level instructions that all providers share are the CLI flags documented in §2.

The key behavioural invariants enforced at the runtime layer:

- **pi runtime**: bench-fence extension intercepts every `read`, `write`, `edit`, `grep`, `find`, `ls`, and `bash` tool call and blocks anything outside the allowlists in §4. The extension is loaded from `<clone>/.pi/extensions/bench-fence/` which the runner installs before `make` is invoked.
- **codex runtime**: `--sandbox workspace-write` restricts writes to the clone directory; no bench-fence JSON file is installed. `BENCH_FORMAL_AUTOFIX=1` is not set for codex.
- **pi/claude runtimes**: `BENCH_FORMAL_AUTOFIX=1` is set. This tells `implement.py` to run the riscv-formal check programmatically and re-invoke the agent with the counterexample tail if the formal gate fails.

All runtimes stream stdout to a per-slot `.agent.*.log` file. The runner concatenates all per-slot logs into `bench/<model>/rep<N>/agent.log` after the run completes.

---

## 8. What the agent sees per round

Each implementation-phase invocation receives the following context (assembled by the orchestrator from the bench clone):

1. **Source RTL** — all `*.sv` files under `cores/bench/rtl/`. Read in full; dumped verbatim into the prompt.
2. **Recent experiment log** — last K=3 entries from `cores/bench/experiments/log.jsonl`. Each entry is one JSONL line: hypothesis prose, fitness numbers, outcome (`accepted`/`rejected`/`broken`/`improvement`/`regression`), and `implementation_notes`.
3. **`LESSONS.md`** — curated append-only log of one-line takeaways from prior iterations, located at `cores/bench/LESSONS.md`. If the file exceeds a threshold the agent is instructed to read it directly rather than having it inlined.
4. **`CORE_PHILOSOPHY.md`** — hard architectural constraints, located at `cores/bench/CORE_PHILOSOPHY.md`.
5. **`core.yaml`** — per-core spec (ISA, target, parameters), located at `cores/bench/core.yaml`.

The hypothesis agent also reads `ARCHITECTURE.md` and `CLAUDE.md` from the clone root, plus the full RTL dump and the recent experiment log.

---

## 9. Verifier gate order

Each hypothesis round runs through the following gates in order. A gate failure marks the iteration `broken` or `rejected` (as appropriate) and stops evaluation for that iteration.

1. **lint** — SystemVerilog lint (`verilator --lint-only` or equivalent). Catches syntax errors and undeclared signals.
2. **synth** — Yosys synthesis to generic gates. Catches elaboration failures.
3. **bench-build** — CocoTB test-bench build (Verilator). Catches type errors visible only after elaboration with the test bench.
4. **cosim-build** — Full Verilator cosim build with the RISC-V test suite.
5. **riscv-formal** — riscv-formal symbolic BMC check. This is the primary correctness gate. A failed formal check produces a counterexample that is fed back to the agent when `BENCH_FORMAL_AUTOFIX=1`.
6. **Verilator cosim** — Cycle-accurate instruction-stream simulation against a golden reference model. Validates instruction-level correctness beyond BMC depth.
7. **3-seed P&R + CoreMark CRC** — Three independent yosys/nextpnr-himbaechel place-and-route runs on the Gowin GW2AR-LV18 (Tang Nano 20K FPGA), each with a different seed. Each seed yields a Fmax estimate and a CoreMark CRC32 check (ensures the synthesised netlist executes coremark correctly). The fitness value reported for an accepted iteration is the **median CoreMark iter/sec** across the three seeds.

A 1-seed P&R run (as in the lite config, `tools/bench/lite.yaml`) is insufficient for a defensible fitness median and is intended only for executability verification.

---

## 10. Frozen tool versions

The bench-fence files that enforce the security boundary of each benchmark run are pinned by hash:

| File | sha256 |
|---|---|
| `tools/bench/fence_validator.py` | `f434d6acba30b88a817b38533201ee9f623644efa155b0adf593e86f9b77d360` |
| `tools/bench/extensions/bench-fence/index.ts` | `f261d77674665462b208a2a4268fe7e9738060f35a85907befb213248a303451` |

These hashes are computed from the `bench-fixture-v1` git ref. To verify:

```bash
git show bench-fixture-v1:tools/bench/fence_validator.py | sha256sum
git show bench-fixture-v1:tools/bench/extensions/bench-fence/index.ts | sha256sum
```

---

## 11. Reproducibility note

A reviewer with the required toolchain (yosys, nextpnr-himbaechel with Gowin GW2AR-LV18 support, riscv-formal, Verilator, CocoTB, and a supported LLM provider API key) can reproduce a single rep with:

```bash
# Reproduce one rep of gpt-5-mini (fast and cheap for smoke-testing)
python -m tools.bench.runner --reps 1 --models gpt-5-mini

# Or with explicit N and K for a minimal run
python -m tools.bench.runner --reps 1 --n 3 --k 1 --models gpt-5-mini
```

The runner clones `bench-fixture-v1` into `.claude/bench-runs/gpt-5-mini-rep1/`, installs the bench-fence extension, and runs `make N=3 K=1 TARGET=bench loop WORKTREE=` in that clone. Results are appended to `bench/results.jsonl`.

For the lite-variant configuration (targeting <2 h wall-clock, <$10), use `tools/bench/lite.yaml` as described in that file's header.

The `bench-fixture-v1` git ref can be checked out directly:

```bash
git fetch origin bench-fixture-v1
git worktree add /tmp/bench-fixture-v1 bench-fixture-v1
```

The fixture is self-contained: it includes the full RTL under `cores/bench/rtl/`, the bench programs, the formal properties, the FPGA constraint files, and the Makefile that drives the evaluation pipeline.
