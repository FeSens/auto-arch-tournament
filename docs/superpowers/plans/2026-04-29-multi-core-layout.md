# Multi-core layout — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the repo from a single `rtl/` to `cores/<name>/` partitions, with a `TARGET=` argument threaded through Makefile, orchestrator, agents, eval, and harness scripts. Add `BASE=` fork-on-create semantics, `core.yaml` per-core spec with auto-updated `current:`, and optional `CORE_PHILOSOPHY.md` prompt injection.

**Architecture:** Three-phase rollout. **Phase A** path-parametrizes every script with `rtl/` as the default fallback (system keeps working unchanged). **Phase B** moves files into `cores/v1/` and `cores/baseline/`, then verifies via `TARGET=v1` and `TARGET=baseline`. **Phase C** drops the `rtl/` fallback (TARGET= becomes required), implements fork-on-create, adds `core.yaml` auto-update, deletes vex stubs, updates docs.

**Tech Stack:** Python 3 (orchestrator + agents + eval), Bash (cosim/formal scripts), Yosys TCL (synth), GNU Make, Git worktrees, cocotb + pytest, Verilator, riscv-formal.

**Spec:** `docs/superpowers/specs/2026-04-29-multi-core-layout-design.md`

---

## File structure

**Created:**
- `cores/baseline/rtl/*.sv` — from `baseline` git tag (the original simple core).
- `cores/baseline/test/` — empty initially; baseline has no cocotb tests at the tag.
- `cores/baseline/core.yaml` — declared targets, empty `current:`.
- `cores/baseline/CORE_PHILOSOPHY.md` — empty file (placeholder).
- `cores/baseline/experiments/` — empty (first run populates).
- `cores/v1/rtl/*.sv` — moved from `rtl/`.
- `cores/v1/test/test_*.py` — moved per-core cocotb tests from `test/`.
- `cores/v1/core.yaml` — declared targets + `current:` from latest log entry.
- `cores/v1/CORE_PHILOSOPHY.md` — empty file (placeholder).
- `cores/v1/experiments/{log.jsonl,progress.png,hypotheses/}` — moved from top-level.

**Modified:**
- `Makefile` — `TARGET=` variable, per-target plumbing.
- `tools/orchestrator.py` — `--target` / `--base` flags, per-core paths, drop `--branch` / `--baseline`.
- `tools/worktree.py` — per-core worktree base path, per-core git-add scope.
- `tools/agents/hypothesis.py` — prompt + lint reference per-core paths; inject `CORE_PHILOSOPHY.md` + `core.yaml`.
- `tools/agents/implement.py` — same as hypothesis.
- `tools/eval/formal.py`, `tools/eval/cosim.py`, `tools/eval/fpga.py` — accept `target` parameter; resolve per-core paths; fpga writes `core.yaml.current`.
- `tools/tournament.py` — thread `target` through round execution.
- `formal/run_all.sh` — `RTL_DIR` + `CORE_NAME` env vars.
- `fpga/scripts/synth.tcl` — `RTL_DIR` env var.
- `test/cosim/build.sh` — `RTL_DIR` + `OBJ_DIR` env vars.
- `.gitignore` — per-core gitignored paths.
- `CLAUDE.md` — don't-touch list and "what hypotheses MAY change" section.
- `README.md` — Model A workflow docs.

**Deleted:**
- `test/cosim/build_vex.sh`
- `test/cosim/vex_main.cpp`

---

## Task ordering rationale

- Phase A tasks (1-9) are individually safe: each adds path-parametrization with backward-compat defaults. Run the full eval suite after each task to confirm nothing regressed.
- Phase B tasks (10-13) move files and verify. The act of moving breaks `make X` without TARGET=, but `make X TARGET=v1` works. We're between "old paths" and "no fallback" — momentary fragility is OK because Phase A made the harness ready.
- Phase C tasks (14-20) finalize: drop fallbacks, add new behavior, clean up.

Each task ends with a commit. Run `make lint`, `make test`, and at least one of `make cosim` / `make formal` / `make fpga` after each task to confirm nothing broke.

---

# Phase A — backward-compatible path-parametrization

## Task 1: Path-parametrize `formal/run_all.sh`

**Files:**
- Modify: `formal/run_all.sh` (add `RTL_DIR` and `CORE_NAME` env var support)

- [ ] **Step 1: Read the current script to identify hardcoded paths**

Run: `cat formal/run_all.sh | head -80`

Note the lines that hardcode `rtl/` (e.g., `cp "$PROJECT_ROOT"/rtl/*.sv "$CORE_DIR/"`) and the `CORE_DIR` definition (currently `formal/riscv-formal/cores/auto-arch-researcher/`).

- [ ] **Step 2: Modify the script to accept `RTL_DIR` and `CORE_NAME` env vars**

At the top of the script (after `set -euo pipefail`), add:

```bash
# Path-parametrization. Defaults preserve the legacy single-rtl/ behavior.
RTL_DIR="${RTL_DIR:-rtl}"
CORE_NAME="${CORE_NAME:-auto-arch-researcher}"
```

Replace every `"$PROJECT_ROOT"/rtl/*.sv` with `"$PROJECT_ROOT"/$RTL_DIR/*.sv`. Replace every `formal/riscv-formal/cores/auto-arch-researcher/` with `formal/riscv-formal/cores/$CORE_NAME/`.

- [ ] **Step 3: Verify the script still runs with default args (backward-compat)**

Run: `make formal`
Expected: Same outcome as before (no path errors). Should produce the existing `last_run.log`.

- [ ] **Step 4: Verify the script runs with explicit env vars matching defaults**

Run: `RTL_DIR=rtl CORE_NAME=auto-arch-researcher bash formal/run_all.sh formal/checks.cfg`
Expected: identical behavior to step 3.

- [ ] **Step 5: Commit**

```bash
git add formal/run_all.sh
git commit -m "formal: parametrize RTL_DIR and CORE_NAME env vars

Defaults preserve the existing rtl/ + auto-arch-researcher behavior.
Phase A of multi-core layout refactor."
```

---

## Task 2: Path-parametrize `fpga/scripts/synth.tcl`

**Files:**
- Modify: `fpga/scripts/synth.tcl` (add `RTL_DIR` env var support)

- [ ] **Step 1: Read the current TCL to identify hardcoded paths**

Run: `cat fpga/scripts/synth.tcl`

Note: `read_verilog -sv rtl/core_pkg.sv` and `glob -nocomplain rtl/*.sv` both hardcode `rtl/`.

- [ ] **Step 2: Modify the TCL to accept `RTL_DIR` from environment**

Near the top of the file (before the first `read_verilog`), add:

```tcl
# Path-parametrization. Default preserves the legacy single-rtl/ behavior.
set rtl_dir "rtl"
if {[info exists ::env(RTL_DIR)]} {
    set rtl_dir $::env(RTL_DIR)
}
```

Replace `read_verilog -sv rtl/core_pkg.sv` with `read_verilog -sv $rtl_dir/core_pkg.sv`. Replace `glob -nocomplain rtl/*.sv` with `glob -nocomplain $rtl_dir/*.sv`.

- [ ] **Step 3: Verify default behavior unchanged**

Run: `make fpga`
Expected: same fmax / lut4 / coremark outcome as before. Wall time ~5-10 min (3-seed nextpnr).

- [ ] **Step 4: Verify explicit env var matches default**

Run: `RTL_DIR=rtl yosys -c fpga/scripts/synth.tcl 2>&1 | tail -20`
Expected: same synth output as step 3 (writes `generated/synth.json`).

- [ ] **Step 5: Commit**

```bash
git add fpga/scripts/synth.tcl
git commit -m "fpga: parametrize RTL_DIR env var in synth.tcl

Default preserves the existing rtl/ behavior. Phase A of multi-core
layout refactor."
```

---

## Task 3: Path-parametrize `test/cosim/build.sh`

**Files:**
- Modify: `test/cosim/build.sh` (add `RTL_DIR` and `OBJ_DIR` env vars)

- [ ] **Step 1: Read the current script**

Run: `cat test/cosim/build.sh`

Note: `RTL_DIR="$REPO_ROOT/rtl"` is the hardcoded line; `OBJ_DIR="$COSIM_DIR/obj_dir"` is the build output.

- [ ] **Step 2: Modify the script to honor pre-existing env vars**

Replace:
```bash
OBJ_DIR="$COSIM_DIR/obj_dir"
RTL_DIR="$REPO_ROOT/rtl"
```

With:
```bash
# Path-parametrization. Defaults preserve the legacy single-rtl/ behavior.
RTL_DIR="${RTL_DIR:-$REPO_ROOT/rtl}"
OBJ_DIR="${OBJ_DIR:-$COSIM_DIR/obj_dir}"
```

(Keep the `# Glob rtl/*.sv` block as-is — it already uses `$RTL_DIR`.)

- [ ] **Step 3: Verify default behavior**

Run: `bash test/cosim/build.sh && ls test/cosim/obj_dir/cosim_sim`
Expected: `cosim_sim` binary exists.

- [ ] **Step 4: Verify cosim still passes end-to-end**

Run: `make cosim`
Expected: same selftest + coremark cosim outcome as before (cosim passes against Python ISS).

- [ ] **Step 5: Commit**

```bash
git add test/cosim/build.sh
git commit -m "cosim: parametrize RTL_DIR and OBJ_DIR env vars in build.sh

Defaults preserve the existing rtl/ + test/cosim/obj_dir behavior.
Phase A of multi-core layout refactor."
```

---

## Task 4: Add `target` parameter to `tools/eval/formal.py`

**Files:**
- Modify: `tools/eval/formal.py` (add optional `target` arg to `run_formal`)

- [ ] **Step 1: Read the current module**

Run: `cat tools/eval/formal.py`

Identify the public entry point (`run_formal(repo_root)`) and the subprocess invocation of `formal/run_all.sh`.

- [ ] **Step 2: Add `target` parameter and pass via env**

Change `run_formal(repo_root)` signature to `run_formal(repo_root, target=None)`. Inside, before the subprocess call, build the env:

```python
env = os.environ.copy()
if target is not None:
    env["RTL_DIR"] = f"cores/{target}/rtl"
    env["CORE_NAME"] = target
```

Pass `env=env` to the `subprocess.run([...formal/run_all.sh...])` call.

- [ ] **Step 3: Verify default behavior (no target) unchanged**

Run: `python3 -c "from tools.eval.formal import run_formal; print(run_formal('.'))"`
Expected: same dict result as before (`{'passed': True/False, ...}`).

- [ ] **Step 4: Run the existing eval test suite**

Run: `pytest tools/ -v 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add tools/eval/formal.py
git commit -m "eval/formal: add optional target parameter

Default (no target) preserves the existing rtl/ behavior. Phase A of
multi-core layout refactor."
```

---

## Task 5: Add `target` parameter to `tools/eval/cosim.py`

**Files:**
- Modify: `tools/eval/cosim.py` (add optional `target` arg to `run_cosim`)

- [ ] **Step 1: Read the current module to find the path resolution**

Run: `cat tools/eval/cosim.py`

Identify the public entry point and any references to `rtl/` or `test/cosim/obj_dir`.

- [ ] **Step 2: Add `target` parameter and pass via env to build.sh + cosim binary**

Change `run_cosim(repo_root)` signature to `run_cosim(repo_root, target=None)`. Where the module invokes `test/cosim/build.sh` (or runs `cosim_sim`), build the env:

```python
env = os.environ.copy()
if target is not None:
    env["RTL_DIR"] = str(Path(repo_root) / "cores" / target / "rtl")
    env["OBJ_DIR"] = str(Path(repo_root) / "cores" / target / "obj_dir")
```

Pass `env=env` to the subprocess. If the module also locates `cosim_sim` directly (not via env), update the path resolution too:
```python
obj_dir = Path(env.get("OBJ_DIR", "test/cosim/obj_dir"))
cosim_sim = obj_dir / "cosim_sim"
```

- [ ] **Step 3: Verify default behavior unchanged**

Run: `python3 -m tools.eval.cosim .`
Expected: same selftest + coremark cosim outcome as `make cosim`.

- [ ] **Step 4: Run the eval test suite**

Run: `pytest tools/ -v 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add tools/eval/cosim.py
git commit -m "eval/cosim: add optional target parameter

Default (no target) preserves the existing rtl/ + obj_dir behavior.
Phase A of multi-core layout refactor."
```

---

## Task 6: Add `target` parameter to `tools/eval/fpga.py`

**Files:**
- Modify: `tools/eval/fpga.py` (add optional `target` arg to `run_fpga_eval`)

- [ ] **Step 1: Read the current module**

Run: `cat tools/eval/fpga.py | head -100`

Identify path references to `rtl/`, `generated/`, `bench/programs/`.

- [ ] **Step 2: Add `target` parameter**

Change `run_fpga_eval(repo_root)` signature to `run_fpga_eval(repo_root, target=None)`. Build env passed to yosys (synth.tcl reads `RTL_DIR`):

```python
env = os.environ.copy()
if target is not None:
    env["RTL_DIR"] = str(Path(repo_root) / "cores" / target / "rtl")
```

Update any `Path(repo_root) / "generated"` to `Path(repo_root) / "cores" / target / "generated"` when target is set; otherwise keep `Path(repo_root) / "generated"` for backward compat.

- [ ] **Step 3: Verify default behavior unchanged**

Run: `python3 -m tools.eval.fpga .`
Expected: same fmax / lut4 / coremark outcome as `make fpga`.

- [ ] **Step 4: Run the eval test suite**

Run: `pytest tools/ -v 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add tools/eval/fpga.py
git commit -m "eval/fpga: add optional target parameter

Default (no target) preserves the existing rtl/ + generated/ behavior.
Phase A of multi-core layout refactor."
```

---

## Task 7: Add `target` parameter to `tools/agents/{hypothesis,implement}.py`

**Files:**
- Modify: `tools/agents/hypothesis.py` (`_build_prompt`, `run_hypothesis_agent`)
- Modify: `tools/agents/implement.py` (prompt + lint command + `run_implementation_agent`)

- [ ] **Step 1: Read both agent modules**

Run: `cat tools/agents/hypothesis.py tools/agents/implement.py | head -200`

Identify hardcoded references to `rtl/` in prompts and the `verilator --lint-only ... rtl/*.sv` lint command.

- [ ] **Step 2: Modify `hypothesis.py` to accept `target` and resolve the rtl dir**

Change `_build_prompt(...)` signature to add a `target: str = None` keyword arg. Inside, replace:
```python
src_files = sorted(Path("rtl").rglob("*.sv"))
```
with:
```python
rtl_dir = Path("cores") / target / "rtl" if target else Path("rtl")
src_files = sorted(rtl_dir.rglob("*.sv"))
```

In the prompt template, replace `## Current SystemVerilog Source (rtl/)` with `## Current SystemVerilog Source ({rtl_dir}/)` (formatted at runtime). Replace `Each \`changes[i].file\` must be a path under rtl/` with `Each \`changes[i].file\` must be a path under {rtl_dir}/`.

Change `run_hypothesis_agent(...)` signature to add `target: str = None`. Pass it through to `_build_prompt`. Don't change the sandbox regex yet — that comes in Phase C.

- [ ] **Step 3: Modify `implement.py` similarly**

Add `target: str = None` to `run_implementation_agent`. Replace the lint command in the implementation prompt:
```python
lint_cmd = ("if ls rtl/*.sv >/dev/null 2>&1; then "
            "verilator --lint-only -Wall -Wno-MULTITOP -sv rtl/*.sv; "
            "else echo 'lint: no source files in rtl/'; exit 1; fi")
```
with a parametrized version:
```python
rtl_glob = f"cores/{target}/rtl/*.sv" if target else "rtl/*.sv"
lint_cmd = (f"if ls {rtl_glob} >/dev/null 2>&1; then "
            f"verilator --lint-only -Wall -Wno-MULTITOP -sv {rtl_glob}; "
            f"else echo 'lint: no source files in {rtl_glob.rsplit('/', 1)[0]}/'; exit 1; fi")
```

Replace any prompt text mentioning `rtl/` with the parametrized path.

- [ ] **Step 4: Run agent unit tests**

Run: `pytest tools/agents/ -v 2>&1 | tail -20`
Expected: existing tests pass (they pass `target=None` implicitly; should be backward-compat).

- [ ] **Step 5: Commit**

```bash
git add tools/agents/hypothesis.py tools/agents/implement.py
git commit -m "agents: add optional target parameter to hypothesis + implement

Defaults (no target) preserve the existing rtl/ behavior. Phase A of
multi-core layout refactor."
```

---

## Task 8: Add `target` parameter to `tools/worktree.py`

**Files:**
- Modify: `tools/worktree.py` (per-core worktree base path; per-core git-add)

- [ ] **Step 1: Re-read the worktree module**

Run: `cat tools/worktree.py`

Identify `WORKTREE_BASE = Path("experiments/worktrees")` and the `git -C <path> add -A rtl/` line.

- [ ] **Step 2: Make `WORKTREE_BASE` a function of `target`**

Change `create_worktree(hypothesis_id, base_branch="main")` to `create_worktree(hypothesis_id, base_branch="main", target=None)`. Inside:

```python
def _worktree_base(target):
    if target is None:
        return Path("experiments/worktrees")
    return Path("cores") / target / "worktrees"

def create_worktree(hypothesis_id, base_branch="main", target=None):
    base = _worktree_base(target)
    base.mkdir(parents=True, exist_ok=True)
    path = str((base / hypothesis_id).resolve())
    ...
```

Apply the same `_worktree_base(target)` helper in `accept_worktree` and `destroy_worktree` (add `target=None` to their signatures too).

In `accept_worktree`, change the git-add scope:
```python
add_path = f"cores/{target}/" if target else "rtl/"
subprocess.run(["git", "-C", path, "add", "-A", add_path], check=True)

test_glob = f"cores/{target}/test/test_*.py" if target else "test/test_*.py"
test_changes = subprocess.run(
    ["git", "-C", path, "ls-files", "--modified", "--others", "--exclude-standard",
     test_glob],
    ...
).stdout.split()
```

- [ ] **Step 3: Run the orchestrator's unit tests**

Run: `pytest tools/test_tournament.py tools/test_accept_rule.py -v 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add tools/worktree.py
git commit -m "worktree: add optional target parameter

Default (no target) preserves the existing experiments/worktrees +
rtl/ behavior. Phase A of multi-core layout refactor."
```

---

## Task 9: Wire `target` through orchestrator + tournament (Phase A integration)

**Files:**
- Modify: `tools/tournament.py` (thread `target` through `run_tournament_round`)
- Modify: `tools/orchestrator.py` (add `--target` flag, no-op if absent)

- [ ] **Step 1: Read `tools/tournament.py` to find `run_tournament_round`**

Run: `grep -n "def run_tournament_round" tools/tournament.py`
Then `sed -n '120,260p' tools/tournament.py` (or read the function in full).

Identify every call to `run_hypothesis_agent`, `run_implementation_agent`, `create_worktree`, `accept_worktree`, `destroy_worktree`, `run_formal`, `run_cosim`, `run_fpga_eval`.

- [ ] **Step 2: Add `target` to `run_tournament_round` signature and pass through**

Change the signature to add `target: str | None = None` as the last keyword argument. Pass `target=target` to every callee identified in step 1.

- [ ] **Step 3: Add `--target` flag to orchestrator (no-op if absent)**

In `tools/orchestrator.py`, add to the argparse setup:
```python
parser.add_argument('--target', default=None,
                    help='Core name under cores/. If absent, uses legacy rtl/ paths.')
```

Pass `target=args.target` to `run_tournament_round` and to `_run_baseline_retest` (which also needs the param; for now, when `target` is None, it operates on `rtl/` as before).

In `_run_baseline_retest`, thread `target` into `emit_verilog`, `run_formal`, `run_cosim`, `run_fpga_eval`. (Note: `emit_verilog` itself needs path-parametrizing — use the same env-var approach as the eval modules. Update its `subprocess.run` calls to set `RTL_DIR` and `OBJ_DIR` env vars when target is set.)

- [ ] **Step 4: Verify orchestrator unit tests pass**

Run: `pytest tools/ -v 2>&1 | tail -30`
Expected: all tests pass.

- [ ] **Step 5: Smoke test the orchestrator without --target (legacy path)**

Run: `make next` (one round, no TARGET=)
Expected: same behavior as today — runs one hypothesis, one eval, logs the result. May take 15-30 min.

(If the smoke test is too long for CI, skip it and rely on unit tests + Phase B's per-core verification.)

- [ ] **Step 6: Commit**

```bash
git add tools/tournament.py tools/orchestrator.py
git commit -m "orchestrator: thread optional --target through tournament round

Default (no --target) preserves the existing rtl/ + experiments/worktrees
+ experiments/log.jsonl behavior. Phase A of multi-core layout refactor."
```

---

# Phase B — migrate files

## Task 10: Move `rtl/` → `cores/v1/rtl/`

**Files:**
- Move: `rtl/*.sv` → `cores/v1/rtl/*.sv`
- Move: `test/test_*.py` (per-core tests) → `cores/v1/test/`
- Move: `experiments/log.jsonl`, `progress.png`, `hypotheses/` → `cores/v1/experiments/`
- Create: `cores/v1/core.yaml`
- Create: `cores/v1/CORE_PHILOSOPHY.md` (empty)

- [ ] **Step 1: Identify which top-level tests are per-core vs infra**

Run: `ls test/test_*.py`
Note which are per-core (test against an `rtl/` module) vs infra (test the orchestrator/accept-rule). Infra ones: `tools/test_accept_rule.py`, `tools/test_tournament.py`, `tools/agents/test_hypothesis.py` — these are already under `tools/`, so won't be touched. The `test/test_*.py` files at the top level are all per-core.

- [ ] **Step 2: Create the cores/v1/ directory structure and move files**

Run:
```bash
mkdir -p cores/v1/test cores/v1/experiments
git mv rtl cores/v1/rtl
git mv test/test_*.py cores/v1/test/
git mv experiments/log.jsonl cores/v1/experiments/log.jsonl
git mv experiments/progress.png cores/v1/experiments/progress.png
git mv experiments/hypotheses cores/v1/experiments/hypotheses
```

(If `experiments/log-<branch>.jsonl` files exist, leave them — they're historical artifacts. Phase C optionally migrates them.)

- [ ] **Step 3: Create `cores/v1/core.yaml`**

Read the latest improvement entry from `cores/v1/experiments/log.jsonl`:
```bash
tail -50 cores/v1/experiments/log.jsonl | grep '"outcome": "improvement"' | tail -1
```

Use that entry's `fmax_mhz`, `lut4`, `ff`, and `coremark_iter_s` (compute `coremark_per_mhz = coremark_iter_s / fmax_mhz`) to populate `current:`. Write:

```yaml
# cores/v1/core.yaml
name: v1
description: Current evolved RV32IM core (5-stage in-order with M-ext, store-slot, hazard/forward).
isa: rv32im
target_fpga: tang-nano-20k

targets:
  fmax_mhz: 90
  lut4: 3000
  coremark_iter_s: 400
  coremark_per_mhz: 4.5

current:
  fmax_mhz: <from latest improvement>
  lut4: <from latest improvement>
  ff: <from latest improvement>
  coremark_iter_s: <from latest improvement>
  coremark_per_mhz: <computed>
  source_id: <from latest improvement>
  updated: <ISO timestamp of that entry>
```

- [ ] **Step 4: Create empty `cores/v1/CORE_PHILOSOPHY.md`**

Run: `touch cores/v1/CORE_PHILOSOPHY.md`

- [ ] **Step 5: Verify `make lint TARGET=v1` works**

This requires the Makefile to be `TARGET=`-aware. Skip until Task 12 then run.

For now, verify directly:
```bash
verilator --lint-only -Wall -Wno-MULTITOP -sv cores/v1/rtl/*.sv
```
Expected: lint passes (same warnings/errors as before the move).

- [ ] **Step 6: Commit**

```bash
git add cores/v1/
git commit -m "cores: migrate current rtl/ into cores/v1/

Move rtl/, per-core cocotb tests, and experiment log+plot+hypotheses
into cores/v1/. Add core.yaml with declared targets and current state
populated from the latest improvement entry. Phase B of multi-core
layout refactor."
```

---

## Task 11: Seed `cores/baseline/` from `baseline` git tag

**Files:**
- Create: `cores/baseline/rtl/*.sv` (from `git archive baseline rtl/`)
- Create: `cores/baseline/test/` (empty)
- Create: `cores/baseline/core.yaml`
- Create: `cores/baseline/CORE_PHILOSOPHY.md` (empty)

- [ ] **Step 1: Verify the `baseline` tag exists and contains rtl/**

Run: `git ls-tree --name-only baseline:rtl`
Expected: list of .sv files (alu.sv, core.sv, etc.) — confirms tag is intact.

- [ ] **Step 2: Extract baseline RTL into cores/baseline/rtl/**

Run:
```bash
mkdir -p cores/baseline/rtl cores/baseline/test cores/baseline/experiments
git archive baseline -- rtl | tar -x -C cores/baseline --strip-components=1 --wildcards 'rtl/*'
ls cores/baseline/rtl/
```

(Cross-check the directory layout — the archive places `rtl/<files>` under the destination; `--strip-components=1` strips the leading `rtl/`. If the `tar -x` form differs on macOS, fall back to: `git show baseline:rtl/<file> > cores/baseline/rtl/<file>` per file.)

Expected: `cores/baseline/rtl/` contains the .sv files from the tag.

- [ ] **Step 3: Create `cores/baseline/core.yaml`**

Write:
```yaml
# cores/baseline/core.yaml
name: baseline
description: Original simple RV32IM core from the baseline git tag — the universal seed for new cores.
isa: rv32im
target_fpga: tang-nano-20k

targets:
  fmax_mhz: 70
  lut4: 2500
  coremark_iter_s: 250
  coremark_per_mhz: 3.5

current:
  # Empty — first orchestrator run on this core will populate via baseline retest.
```

- [ ] **Step 4: Create empty CORE_PHILOSOPHY.md**

Run: `touch cores/baseline/CORE_PHILOSOPHY.md`

- [ ] **Step 5: Verify `cores/baseline/rtl/` lints**

Run: `verilator --lint-only -Wall -Wno-MULTITOP -sv cores/baseline/rtl/*.sv`
Expected: lint passes (it's the original simple core that we know works).

- [ ] **Step 6: Commit**

```bash
git add cores/baseline/
git commit -m "cores: seed cores/baseline from the baseline git tag

The baseline core is the universal fork seed for new cores. Sourced
from the baseline tag (the original simple RV32IM core). Phase B of
multi-core layout refactor."
```

---

## Task 12: Update Makefile for `TARGET=` plumbing

**Files:**
- Modify: `Makefile` (add `TARGET=` variable; per-target plumbing; help text)

- [ ] **Step 1: Read the current Makefile**

Run: `cat Makefile`

Note all targets that touch RTL: `lint`, `test`, `cosim`, `cosim-build`, `formal`, `fpga`, `next`, `loop`, `report`, `generated/synth.json` rule.

- [ ] **Step 2: Add `TARGET=` variable and helpers**

After the existing variable block (around line 44), add:

```makefile
# Multi-core: TARGET selects the core under cores/<TARGET>/. Empty TARGET
# falls back to the legacy single-rtl/ behavior (kept during Phase A/B
# migration; removed in Phase C).
TARGET ?=

ifneq ($(strip $(TARGET)),)
  RTL_DIR    := cores/$(TARGET)/rtl
  TEST_DIR   := cores/$(TARGET)/test
  CORE_NAME  := $(TARGET)
  OBJ_DIR    := cores/$(TARGET)/obj_dir
  GEN_DIR    := cores/$(TARGET)/generated
  ORCH_TARGET_FLAG := --target $(TARGET)
else
  RTL_DIR    := rtl
  TEST_DIR   := test
  CORE_NAME  := auto-arch-researcher
  OBJ_DIR    := test/cosim/obj_dir
  GEN_DIR    := generated
  ORCH_TARGET_FLAG :=
endif

export RTL_DIR CORE_NAME OBJ_DIR
```

- [ ] **Step 3: Update the `lint` target**

Replace:
```makefile
lint:
	@if ls rtl/*.sv >/dev/null 2>&1; then \
	  verilator --lint-only -Wall -Wno-MULTITOP -sv rtl/*.sv; \
	else \
	  echo "lint: no source files in rtl/ (phase 0 — expected)"; \
	fi
```

With:
```makefile
lint:
	@if ls $(RTL_DIR)/*.sv >/dev/null 2>&1; then \
	  verilator --lint-only -Wall -Wno-MULTITOP -sv $(RTL_DIR)/*.sv; \
	else \
	  echo "lint: no source files in $(RTL_DIR)/"; \
	fi
```

- [ ] **Step 4: Update the `test` target**

Replace `pytest -v test/` with `pytest -v $(TEST_DIR)/` (when TARGET is set, runs cores/<TARGET>/test; otherwise legacy `test/`).

Also keep a separate `test-infra` target that always runs the top-level infra tests (so they're easy to run without a target):
```makefile
test-infra:
	pytest -v tools/
```

- [ ] **Step 5: Update `cosim`, `cosim-build`, `fpga`, `formal`, `generated/synth.json` targets**

Replace `rtl/*.sv` with `$(RTL_DIR)/*.sv`. Replace `test/cosim/obj_dir` with `$(OBJ_DIR)`. Replace `generated/` with `$(GEN_DIR)/`.

Specifically:
- `cosim-build: $(wildcard $(RTL_DIR)/*.sv) test/cosim/main.cpp` (the rule still calls `bash test/cosim/build.sh` — env vars are exported).
- `cosim:` body becomes `python3 -m tools.eval.cosim . $(if $(TARGET),--target $(TARGET))` (or update cosim.py to accept argv).
- `fpga:` body becomes `python3 -m tools.eval.fpga . $(if $(TARGET),--target $(TARGET))`.
- `generated/synth.json:` rule body becomes `mkdir -p $(GEN_DIR) && yosys -c fpga/scripts/synth.tcl` (env vars carry RTL_DIR through).

(Note: this requires that `tools/eval/cosim.py` and `tools/eval/fpga.py` accept a `--target` CLI arg if they have a `__main__` block. Add it if missing — small change; argparse already exists in some.)

- [ ] **Step 6: Update `next`, `loop`, `report` targets**

```makefile
next:
	AGENT_PROVIDER=$(AGENT) python3 -m tools.orchestrator $(subst --iterations $(N),--iterations 1,$(ORCH_FLAGS)) $(ORCH_TARGET_FLAG)

loop:
	AGENT_PROVIDER=$(AGENT) python3 -m tools.orchestrator $(ORCH_FLAGS) $(ORCH_TARGET_FLAG)

report:
	python3 -m tools.orchestrator --report $(ORCH_TARGET_FLAG)
```

- [ ] **Step 7: Update `help` text**

Mention that every core-touching target accepts `TARGET=<name>` and lists discovered cores:
```makefile
help:
	@echo "Targets (most accept TARGET=<core_name>):"
	@echo "  make lint       — verilator lint over cores/<TARGET>/rtl/*.sv (or legacy rtl/)"
	@echo "  make test       — cocotb unit tests under cores/<TARGET>/test/ (or legacy test/)"
	@echo "  make cosim      — RVFI cosim against Python ISS"
	@echo "  ..."
	@echo ""
	@echo "Available cores:"
	@for d in cores/*/; do echo "  - $$(basename $$d)"; done 2>/dev/null || echo "  (none — falls back to rtl/)"
```

- [ ] **Step 8: Verify legacy default still works**

Run: `make lint`
Expected: depending on whether `rtl/` still exists at this point — if Task 10 already moved it, `lint` (no TARGET) will say "no source files in rtl/". That's expected.

Run: `make lint TARGET=v1`
Expected: lints `cores/v1/rtl/*.sv` and passes.

Run: `make lint TARGET=baseline`
Expected: lints `cores/baseline/rtl/*.sv` and passes.

- [ ] **Step 9: Verify cosim and fpga work with TARGET=**

Run: `make cosim TARGET=v1`
Expected: cosim passes (selftest + coremark CRCs match).

Run: `make formal TARGET=v1`
Expected: formal passes (same outcome as before the migration).

(`make fpga TARGET=v1` takes ~10 min; defer to Task 13's full sweep.)

- [ ] **Step 10: Commit**

```bash
git add Makefile
git commit -m "make: add TARGET= variable and per-target plumbing

TARGET selects cores/<TARGET>/ paths; empty TARGET keeps the legacy
rtl/ behavior for the migration window. Phase B of multi-core layout
refactor."
```

---

## Task 13: Full eval sweep on both cores

**Files:** none modified — verification only.

- [ ] **Step 1: Run the full eval suite on `cores/v1/`**

```bash
make lint TARGET=v1
make test TARGET=v1
make cosim TARGET=v1
make formal TARGET=v1
make fpga TARGET=v1
```

Expected: every command exits 0. fpga's outcome should match the most recent improvement in the original `experiments/log.jsonl`.

If anything fails: stop, debug, and fix the specific path issue. Do not proceed until v1 passes the full suite under the new layout.

- [ ] **Step 2: Run the eval suite on `cores/baseline/`**

```bash
make lint TARGET=baseline
make cosim TARGET=baseline
make formal TARGET=baseline
make fpga TARGET=baseline
```

(Skip `make test TARGET=baseline` — baseline has no cocotb tests.)

Expected: every command exits 0. baseline is the original simple core known to be correct; if `make formal TARGET=baseline` fails, the baseline tag is suspect, not the refactor.

Record baseline's measured fitness: read `make report TARGET=baseline` (or check the log it just wrote — actually the log isn't written by make targets, only by orchestrator runs; just observe stdout).

- [ ] **Step 3: Commit a no-op marker if you want a clean checkpoint, otherwise skip**

(Optional checkpoint for bisectability — usually not needed.)

```bash
git commit --allow-empty -m "checkpoint: cores/v1 and cores/baseline pass full eval suite under new layout"
```

---

# Phase C — drop fallback, add fork-on-create, finalize

## Task 14: Drop legacy `rtl/` fallback in scripts

**Files:**
- Modify: `formal/run_all.sh` (require `RTL_DIR`)
- Modify: `fpga/scripts/synth.tcl` (require `RTL_DIR`)
- Modify: `test/cosim/build.sh` (require `RTL_DIR`)

- [ ] **Step 1: Make `RTL_DIR` required in `formal/run_all.sh`**

Replace:
```bash
RTL_DIR="${RTL_DIR:-rtl}"
CORE_NAME="${CORE_NAME:-auto-arch-researcher}"
```

With:
```bash
if [ -z "${RTL_DIR:-}" ] || [ -z "${CORE_NAME:-}" ]; then
  echo "ERROR: formal/run_all.sh requires RTL_DIR and CORE_NAME env vars." >&2
  echo "  Example: RTL_DIR=cores/v1/rtl CORE_NAME=v1 bash formal/run_all.sh formal/checks.cfg" >&2
  exit 2
fi
```

- [ ] **Step 2: Make `RTL_DIR` required in `fpga/scripts/synth.tcl`**

Replace the default-fallback block:
```tcl
set rtl_dir "rtl"
if {[info exists ::env(RTL_DIR)]} {
    set rtl_dir $::env(RTL_DIR)
}
```

With:
```tcl
if {![info exists ::env(RTL_DIR)]} {
    error "synth.tcl requires the RTL_DIR env var (e.g. RTL_DIR=cores/v1/rtl)."
}
set rtl_dir $::env(RTL_DIR)
```

- [ ] **Step 3: Make `RTL_DIR` required in `test/cosim/build.sh`**

Replace:
```bash
RTL_DIR="${RTL_DIR:-$REPO_ROOT/rtl}"
OBJ_DIR="${OBJ_DIR:-$COSIM_DIR/obj_dir}"
```

With:
```bash
if [ -z "${RTL_DIR:-}" ] || [ -z "${OBJ_DIR:-}" ]; then
  echo "ERROR: test/cosim/build.sh requires RTL_DIR and OBJ_DIR env vars." >&2
  echo "  Example: RTL_DIR=cores/v1/rtl OBJ_DIR=cores/v1/obj_dir bash test/cosim/build.sh" >&2
  exit 2
fi
```

- [ ] **Step 4: Verify TARGET= still drives every command**

```bash
make lint TARGET=v1 && make formal TARGET=v1 && make cosim TARGET=v1
```
Expected: all pass.

- [ ] **Step 5: Verify the no-TARGET form fails cleanly**

Run: `bash formal/run_all.sh formal/checks.cfg` (no env vars)
Expected: prints "ERROR: formal/run_all.sh requires RTL_DIR and CORE_NAME env vars." and exits 2.

- [ ] **Step 6: Commit**

```bash
git add formal/run_all.sh fpga/scripts/synth.tcl test/cosim/build.sh
git commit -m "harness: require RTL_DIR/OBJ_DIR/CORE_NAME (drop rtl/ fallback)

Phase C of multi-core layout refactor. All callers (Makefile, eval
modules, orchestrator) now pass these via env vars. The legacy rtl/
fallback was a Phase A/B migration aid; with cores/v1/ and
cores/baseline/ both verified, the fallback is no longer needed."
```

---

## Task 15: Make `--target` required in orchestrator; drop `--branch` / `--baseline`

**Files:**
- Modify: `tools/orchestrator.py` (require `--target`; drop `--branch` / `--baseline`)
- Modify: `tools/orchestrator.py` (per-core `LOG_PATH` / `PLOT_PATH`)
- Modify: `tools/orchestrator.py` (per-core `ALLOWED_PATTERNS`)
- Modify: `Makefile` (TARGET= becomes required for core-touching targets)

- [ ] **Step 1: Drop `--branch` / `--baseline` flags**

In `tools/orchestrator.py`'s argparse setup, remove:
```python
parser.add_argument('--branch', default=None, ...)
parser.add_argument('--baseline', default=None, ...)
```

And remove the related logic blocks: `_branch_exists`, `_ensure_branch`, the branch-lifecycle section in `main()`, the `target_branch = args.branch or "main"` resolution (replace with `target_branch = "main"` since branches are now user-managed). Keep `_run_baseline_retest` — it's still needed for fork-on-create (Task 16).

- [ ] **Step 2: Make `--target` required**

```python
parser.add_argument('--target', required=True,
                    help='Core name under cores/. Required.')
```

Add a special case for `--report`: it can run without `--target` to list all cores' summaries; with `--target foo` it shows that one core's report.

- [ ] **Step 3: Make `LOG_PATH` and `PLOT_PATH` per-core**

Replace the module-level constants:
```python
LOG_PATH       = Path("experiments/log.jsonl")
PLOT_PATH      = Path("experiments/progress.png")
```

With a function:
```python
def log_path_for(target: str) -> Path:
    return Path("cores") / target / "experiments" / "log.jsonl"

def plot_path_for(target: str) -> Path:
    return Path("cores") / target / "experiments" / "progress.png"
```

In `main()`, after parsing args:
```python
LOG_PATH = log_path_for(args.target)
PLOT_PATH = plot_path_for(args.target)
```

(Or refactor `read_log` / `append_log` to take paths as args; simpler to keep the global module variables for now.)

- [ ] **Step 4: Make `ALLOWED_PATTERNS` per-target**

Replace the module-level constant with a builder:
```python
def allowed_patterns_for(target: str) -> tuple:
    base = re.escape(f"cores/{target}")
    return (
        re.compile(rf"^{base}/rtl/.+"),
        re.compile(rf"^{base}/test/test_[^/]+\.py$"),
        re.compile(rf"^{base}/implementation_notes\.md$"),
        re.compile(rf"^{base}/core\.yaml$"),
    )
```

Update `path_is_allowed` and `offlimits_changes` to take `target` (or to take pre-built patterns). Pass through from `main()`.

- [ ] **Step 5: Update `Makefile` to require TARGET= for core-touching targets**

In the `TARGET ?=` block, add a guard for core-touching targets:
```makefile
# Targets that require TARGET=<core_name>.
CORE_TARGETS := lint test cosim cosim-build formal formal-deep fpga next loop

ifeq ($(strip $(TARGET)),)
  ifneq ($(filter $(MAKECMDGOALS),$(CORE_TARGETS)),)
    $(error TARGET= required. Available cores: $(notdir $(wildcard cores/*)))
  endif
endif
```

Also drop the legacy `else` branch that defaulted `RTL_DIR := rtl`. The `ifneq ($(strip $(TARGET)),)` guard is no longer needed because TARGET is required for these goals.

- [ ] **Step 6: Verify the new error messages are clear**

Run: `make lint`
Expected: error message: "TARGET= required. Available cores: baseline v1"

Run: `make lint TARGET=v1`
Expected: lint passes.

Run: `python3 -m tools.orchestrator --iterations 1`
Expected: argparse error: "--target is required".

Run: `python3 -m tools.orchestrator --report`
Expected: prints a summary across all cores (or fails gracefully if --report logic isn't yet generalized — fix that too).

- [ ] **Step 7: Run the tests**

Run: `pytest tools/ -v 2>&1 | tail -30`
Expected: all tests pass. (May need to update tests that called `run_tournament_round` or the orchestrator without `target=`; pass `target='v1'` in those tests.)

- [ ] **Step 8: Commit**

```bash
git add tools/orchestrator.py Makefile
git commit -m "orchestrator: require --target; drop --branch and --baseline

Branches are now user-managed (one branch per core, manual PR to main).
The orchestrator only sees filesystem state. Per-core LOG_PATH,
PLOT_PATH, and ALLOWED_PATTERNS. Phase C of multi-core layout refactor."
```

---

## Task 16: Implement fork-on-create (`--base` flag)

**Files:**
- Modify: `tools/orchestrator.py` (add `--base`; fork logic; TTY-gated philosophy prompt)
- Create: `tools/test_orchestrator_fork.py` (new test file for fork behavior)

- [ ] **Step 1: Write a failing test for the fork-on-create flow**

Create `tools/test_orchestrator_fork.py`:

```python
"""Fork-on-create semantics: cores/foo absent + BASE=bar → fork from bar."""
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest


def _setup_repo(tmp: Path):
    """Create a minimal cores/baseline structure and init a git repo."""
    subprocess.run(["git", "init"], cwd=tmp, check=True, capture_output=True)
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
                    "commit", "--allow-empty", "-m", "init"],
                   cwd=tmp, check=True, capture_output=True)
    bl_rtl = tmp / "cores" / "baseline" / "rtl"
    bl_test = tmp / "cores" / "baseline" / "test"
    bl_rtl.mkdir(parents=True)
    bl_test.mkdir(parents=True)
    (bl_rtl / "core.sv").write_text("module core(); endmodule\n")
    (tmp / "cores" / "baseline" / "core.yaml").write_text(
        "name: baseline\nisa: rv32im\ntarget_fpga: x\ntargets: {}\ncurrent: {}\n"
    )
    (tmp / "cores" / "baseline" / "CORE_PHILOSOPHY.md").write_text("")
    subprocess.run(["git", "add", "."], cwd=tmp, check=True, capture_output=True)
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
                    "commit", "-m", "seed baseline"],
                   cwd=tmp, check=True, capture_output=True)


def test_fork_creates_target_from_base(tmp_path):
    _setup_repo(tmp_path)
    # Import the function under test (lazy to avoid import-time path resolution).
    import sys
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from tools.orchestrator import fork_core

    # Headless mode (no TTY) so the philosophy prompt is skipped.
    fork_core(target="foo", base="baseline", repo_root=tmp_path, interactive=False)

    # Verify the new core's structure.
    foo = tmp_path / "cores" / "foo"
    assert (foo / "rtl" / "core.sv").exists()
    assert (foo / "test").is_dir()
    assert (foo / "core.yaml").exists()
    assert (foo / "CORE_PHILOSOPHY.md").exists()  # empty file from headless skip
    assert (foo / "CORE_PHILOSOPHY.md").read_text() == ""
    # core.yaml should have current: cleared but targets: carried.
    yaml_text = (foo / "core.yaml").read_text()
    assert "name: baseline" not in yaml_text  # name should be rewritten to foo
    assert "name: foo" in yaml_text or "name:" in yaml_text


def test_fork_errors_if_target_exists(tmp_path):
    _setup_repo(tmp_path)
    (tmp_path / "cores" / "foo").mkdir()
    import sys
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from tools.orchestrator import fork_core

    with pytest.raises(SystemExit, match="already exists"):
        fork_core(target="foo", base="baseline", repo_root=tmp_path, interactive=False)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pytest tools/test_orchestrator_fork.py -v`
Expected: FAIL with "ImportError: cannot import name 'fork_core' from tools.orchestrator" (or similar — the function doesn't exist yet).

- [ ] **Step 3: Implement `fork_core` in `tools/orchestrator.py`**

Add to the orchestrator:

```python
def fork_core(target: str, base: str, repo_root: Path | None = None,
              interactive: bool | None = None) -> None:
    """Create cores/<target>/ by forking from cores/<base>/.

    Copies rtl/, test/, core.yaml from base. Does NOT copy CORE_PHILOSOPHY.md
    (always per-core). Does NOT copy experiments/ (new core gets its own log).
    Resets core.yaml's current: section. Prompts user for philosophy via TTY
    if interactive (None → auto-detect from sys.stdin.isatty()).
    """
    repo_root = Path(repo_root or ".").resolve()
    tgt = repo_root / "cores" / target
    src = repo_root / "cores" / base

    if tgt.exists():
        raise SystemExit(
            f"cores/{target}/ already exists. Drop BASE= to continue iterating, "
            f"or `git rm -r cores/{target}` to start over."
        )
    if not src.exists():
        raise SystemExit(f"BASE core 'cores/{base}/' does not exist.")

    tgt.mkdir(parents=True)
    # Copy rtl/ and test/ trees.
    if (src / "rtl").exists():
        shutil.copytree(src / "rtl", tgt / "rtl")
    (tgt / "test").mkdir(exist_ok=True)
    if (src / "test").exists():
        for p in (src / "test").glob("test_*.py"):
            shutil.copy2(p, tgt / "test" / p.name)
    # Copy and rewrite core.yaml.
    if (src / "core.yaml").exists():
        y = yaml.safe_load((src / "core.yaml").read_text())
        y["name"] = target
        y["current"] = {}
        (tgt / "core.yaml").write_text(yaml.safe_dump(y, sort_keys=False))
    # Always create an empty experiments/ for the new core.
    (tgt / "experiments").mkdir(exist_ok=True)
    # Philosophy prompt (TTY-gated).
    philo = tgt / "CORE_PHILOSOPHY.md"
    if interactive is None:
        interactive = sys.stdin.isatty()
    if interactive:
        sys.stderr.write(
            f"Optional: write the philosophy for cores/{target} (constraints, "
            f"style, intent).\nPress Ctrl-D / empty + Enter to skip.\n"
        )
        sys.stderr.flush()
        text = sys.stdin.read()
        philo.write_text(text)
    else:
        philo.write_text("")  # silent, headless-safe.
    # Commit the fork.
    subprocess.run(["git", "-C", str(repo_root), "add", f"cores/{target}/"],
                   check=True)
    subprocess.run(
        ["git", "-C", str(repo_root), "commit", "-m",
         f"feat: fork cores/{target} from cores/{base}"],
        check=True,
    )
```

In `main()`, add `--base` flag and the fork-on-missing logic:

```python
parser.add_argument('--base', default='baseline',
                    help='When forking a new --target, copy from cores/<base>/. '
                         'Default: baseline. Ignored if --target already exists.')

# After parsing args, before the round loop:
target_dir = Path("cores") / args.target
if not target_dir.exists():
    fork_core(args.target, args.base)
    # Run baseline retest on the freshly forked core.
    print(f"[orchestrator] freshly forked cores/{args.target} — running baseline retest",
          flush=True)
    _run_baseline_retest(args.target)
```

Update `_run_baseline_retest` to accept a `target` parameter and use the per-core paths.

- [ ] **Step 4: Run the test to verify it passes**

Run: `pytest tools/test_orchestrator_fork.py -v`
Expected: PASS.

- [ ] **Step 5: Manual smoke test — fork a fresh core and run one iteration**

```bash
make loop TARGET=smoke BASE=baseline N=1
```

Expected: creates `cores/smoke/` (with rtl/, test/, core.yaml, empty CORE_PHILOSOPHY.md, empty experiments/), runs the baseline retest (writes first log entry), runs one tournament round, commits log + iteration result. Then:

```bash
ls cores/smoke/
cat cores/smoke/experiments/log.jsonl | head -2  # baseline + first iteration
```

Expected: structure looks right; log has at least one entry.

After verification, clean up:
```bash
git rm -r cores/smoke
git commit -m "test: clean up smoke-test fork"
```

(This commit can be reverted later if the fork itself is interesting to preserve.)

- [ ] **Step 6: Commit**

```bash
git add tools/orchestrator.py tools/test_orchestrator_fork.py
git commit -m "orchestrator: add --base fork-on-create with TTY-gated philosophy prompt

When --target doesn't exist as cores/<target>/, fork from cores/<base>/
(default base=baseline). Copies rtl/, test/, and core.yaml; rewrites
name; clears current; always per-core CORE_PHILOSOPHY.md (prompted
in interactive mode, silently empty in headless). Phase C of multi-core
layout refactor."
```

---

## Task 17: Auto-update `core.yaml.current:` on accepted improvement

**Files:**
- Modify: `tools/eval/fpga.py` (or `tools/orchestrator.py`'s accept path)
- Create: `tools/test_core_yaml_update.py`

- [ ] **Step 1: Write a failing test**

Create `tools/test_core_yaml_update.py`:

```python
"""core.yaml auto-update: after a successful fpga eval, current: section
reflects the latest measured fitness."""
from pathlib import Path
import yaml


def test_update_current_writes_yaml(tmp_path):
    # Setup a minimal core.yaml.
    core_dir = tmp_path / "cores" / "v1"
    core_dir.mkdir(parents=True)
    (core_dir / "core.yaml").write_text(
        "name: v1\nisa: rv32im\ntarget_fpga: x\n"
        "targets:\n  fmax_mhz: 90\ncurrent: {}\n"
    )

    from tools.orchestrator import update_core_yaml_current
    update_core_yaml_current(
        target="v1", repo_root=tmp_path,
        fmax_mhz=78.4, lut4=2647, ff=1834,
        coremark_iter_s=312.6,
        source_id="hyp-test-001",
    )

    y = yaml.safe_load((core_dir / "core.yaml").read_text())
    assert y["current"]["fmax_mhz"] == 78.4
    assert y["current"]["lut4"] == 2647
    assert y["current"]["coremark_per_mhz"] == round(312.6 / 78.4, 4)
    assert y["current"]["source_id"] == "hyp-test-001"
    assert "updated" in y["current"]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pytest tools/test_core_yaml_update.py -v`
Expected: FAIL with "ImportError: cannot import name 'update_core_yaml_current'".

- [ ] **Step 3: Implement `update_core_yaml_current` in `tools/orchestrator.py`**

```python
def update_core_yaml_current(target: str, repo_root: Path | None = None, *,
                              fmax_mhz: float, lut4: int, ff: int,
                              coremark_iter_s: float, source_id: str) -> None:
    """Write the `current:` section of cores/<target>/core.yaml.

    Called from the accept path (after run_fpga_eval succeeds and the
    hypothesis is accepted as an improvement).
    """
    repo_root = Path(repo_root or ".").resolve()
    yaml_path = repo_root / "cores" / target / "core.yaml"
    if not yaml_path.exists():
        return  # no yaml to update; older cores may not have one.
    y = yaml.safe_load(yaml_path.read_text()) or {}
    y["current"] = {
        "fmax_mhz": fmax_mhz,
        "lut4": lut4,
        "ff": ff,
        "coremark_iter_s": coremark_iter_s,
        "coremark_per_mhz": round(coremark_iter_s / fmax_mhz, 4) if fmax_mhz else None,
        "source_id": source_id,
        "updated": datetime.datetime.utcnow().isoformat() + "Z",
    }
    yaml_path.write_text(yaml.safe_dump(y, sort_keys=False))
```

- [ ] **Step 4: Wire into the accept path**

In `tools/orchestrator.py`, derive the target from the per-target `LOG_PATH` set in `main()` (Task 15 made it `cores/<target>/experiments/log.jsonl`). Add at module level:

```python
def _current_target() -> str | None:
    """Extract target from LOG_PATH (set in main() to cores/<target>/experiments/log.jsonl)."""
    parts = LOG_PATH.parts
    if len(parts) >= 2 and parts[0] == "cores":
        return parts[1]
    return None
```

In `append_log`, after writing the log entry and before the git commit, call:

```python
target = _current_target()
if target and entry.get("outcome") == "improvement":
    yaml_path = Path("cores") / target / "core.yaml"
    update_core_yaml_current(
        target=target,
        fmax_mhz=entry["fmax_mhz"],
        lut4=entry["lut4"],
        ff=entry["ff"],
        coremark_iter_s=entry.get("coremark_iter_s") or entry.get("ipc_coremark"),
        source_id=entry["id"],
    )
    if yaml_path.exists():
        subprocess.run(["git", "add", str(yaml_path)], check=True)
```

The `git add` for `core.yaml` lands in the same commit as the existing log + plot adds (`append_log` already batches `git add LOG_PATH` and `git add PLOT_PATH` before the single `git commit`; the `core.yaml` add slots in there).

- [ ] **Step 5: Run the test to verify it passes**

Run: `pytest tools/test_core_yaml_update.py -v`
Expected: PASS.

- [ ] **Step 6: Smoke test end-to-end**

Run a one-iteration loop on v1 and verify `core.yaml` updates:

```bash
make loop TARGET=v1 N=1
cat cores/v1/core.yaml | grep -A 8 'current:'
```

Expected: `current:` section is populated (or refreshed) with the latest measured numbers and an `updated:` timestamp.

- [ ] **Step 7: Commit**

```bash
git add tools/orchestrator.py tools/test_core_yaml_update.py
git commit -m "orchestrator: auto-update core.yaml current: on accepted improvement

After each accepted improvement, write fmax/lut4/ff/coremark/source_id/
updated to cores/<target>/core.yaml current: section. Folded into the
existing log + plot commit. Phase C of multi-core layout refactor."
```

---

## Task 18: Inject `CORE_PHILOSOPHY.md` and `core.yaml` into agent prompts

**Files:**
- Modify: `tools/agents/hypothesis.py` (`_build_prompt` injects philosophy + targets)
- Modify: `tools/agents/implement.py` (`_build_prompt` injects philosophy)

- [ ] **Step 1: Update `hypothesis.py`'s `_build_prompt`**

When `target` is set, read `cores/<target>/CORE_PHILOSOPHY.md` and `cores/<target>/core.yaml`, and inject:

```python
philosophy = ""
if target:
    philo_path = Path("cores") / target / "CORE_PHILOSOPHY.md"
    if philo_path.exists() and philo_path.read_text().strip():
        philosophy = (
            f"## Core philosophy / architect's hard constraints\n"
            f"{philo_path.read_text()}\n\n"
        )

core_yaml_block = ""
if target:
    yaml_path = Path("cores") / target / "core.yaml"
    if yaml_path.exists():
        core_yaml_block = (
            f"## Core spec (cores/{target}/core.yaml)\n"
            f"```yaml\n{yaml_path.read_text()}```\n\n"
        )
```

Insert `{philosophy}{core_yaml_block}` near the top of the prompt body, after the opening fitness-context lines and before `## Architecture`.

- [ ] **Step 2: Update `implement.py`'s `_build_prompt` similarly**

Same pattern — inject philosophy block. Don't inject the full `core.yaml` for the implement agent (it's just executing the hypothesis; the philosophy is the part it needs to respect).

- [ ] **Step 3: Manual verification**

Add a sample philosophy and run one iteration:

```bash
echo "Minimize LUT4 above all else. Reject any hypothesis that exceeds 2900 LUT4 even if fitness improves." > cores/v1/CORE_PHILOSOPHY.md
git add cores/v1/CORE_PHILOSOPHY.md
git commit -m "test: temporary philosophy for v1 to verify prompt injection"
make next TARGET=v1
# Inspect the agent log to confirm the philosophy text appears in the prompt:
grep -A 3 "Core philosophy" cores/v1/experiments/hypotheses/.agent.*.log | head -10
```

Expected: the agent's log shows the philosophy block in the prompt.

After verification, revert the test philosophy:
```bash
echo -n "" > cores/v1/CORE_PHILOSOPHY.md
git add cores/v1/CORE_PHILOSOPHY.md
git commit -m "test: revert temporary philosophy"
```

- [ ] **Step 4: Commit**

```bash
git add tools/agents/hypothesis.py tools/agents/implement.py
git commit -m "agents: inject CORE_PHILOSOPHY.md and core.yaml into prompts

Per-target injection. Empty/missing philosophy is silently skipped.
Phase C of multi-core layout refactor."
```

---

## Task 19: Delete vex stubs; update .gitignore; update CLAUDE.md

**Files:**
- Delete: `test/cosim/build_vex.sh`, `test/cosim/vex_main.cpp`
- Modify: `.gitignore`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Delete vex stubs**

Run:
```bash
git rm test/cosim/build_vex.sh test/cosim/vex_main.cpp
```

Verify no references remain:
```bash
grep -rn "vex_main\|build_vex" --exclude-dir=.git --exclude-dir=__pycache__ . || echo "no references"
```
Expected: "no references" (or only a reference in this plan doc, which is fine).

- [ ] **Step 2: Update `.gitignore`**

Read current `.gitignore`:
```bash
cat .gitignore
```

Add (and remove the now-obsolete `experiments/worktrees/` line if present):

```
# Per-core gitignored paths (Phase C)
cores/*/worktrees/
cores/*/generated/
cores/*/obj_dir/
cores/*/implementation_notes.md
```

- [ ] **Step 3: Update CLAUDE.md don't-touch list**

Edit the section that begins with "Don't-touch list (the orchestrator never modifies these)". Keep the same structure but update path references:
- `tools/`, `schemas/` — unchanged.
- `formal/wrapper.sv`, `formal/checks.cfg`, `formal/run_all.sh` — unchanged.
- `formal/riscv-formal/` — unchanged.
- `bench/programs/` — unchanged.
- `fpga/CoreBench.sv`, `fpga/scripts/*`, `fpga/constraints/*` — unchanged.
- `test/cosim/main.cpp`, `test/cosim/reference.py`, `test/cosim/run_cosim.py` — unchanged.
- This file (`CLAUDE.md`), `ARCHITECTURE.md`, `README.md`, `setup.sh`, `Makefile` — unchanged.

In the "What hypotheses MAY change" section, replace:
```
Everything under `rtl/` and the cocotb unit tests under `test/`.
```
With:
```
Everything under `cores/<TARGET>/rtl/` and the cocotb unit tests under
`cores/<TARGET>/test/test_*.py`. The agent's `implementation_notes.md`
lives at `cores/<TARGET>/implementation_notes.md` (gitignored). The
orchestrator may also update `cores/<TARGET>/core.yaml` (current:
section only).
```

In the "must not" list, replace:
```
- Modify any path in the don't-touch list.
```
With (no change — still applies). Add:
```
- Edit any other core's directory (cores/<other>/...). Each loop is
  scoped to a single TARGET.
```

- [ ] **Step 4: Verify no test breakage**

Run: `pytest tools/ -v 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add test/cosim/build_vex.sh test/cosim/vex_main.cpp .gitignore CLAUDE.md
git commit -m "cleanup: delete vex stubs; update .gitignore + CLAUDE.md for cores/

Vex stubs (build_vex.sh, vex_main.cpp) replaced by future cores/vex/
when needed. Per-core gitignored paths added. CLAUDE.md don't-touch
and may-change sections updated for cores/<TARGET>/. Phase C of
multi-core layout refactor."
```

---

## Task 20: Update README.md with Model A workflow

**Files:**
- Modify: `README.md` (Model A workflow docs; cores/baseline + cores/v1 explanation)

- [ ] **Step 1: Read README.md to find the right insertion point**

Run: `cat README.md | head -80`

Find the section that explains how to run a loop / iterate on the design.

- [ ] **Step 2: Add a "Multiple cores" section**

Insert (positioning at the editor's discretion):

````markdown
## Working with multiple cores

The repo holds multiple core architectures under `cores/<name>/`. Each core has
its own RTL, cocotb tests, experiment log, and progress chart.

**Available cores:**
- `cores/baseline/` — the original simple RV32IM core (from the `baseline` git
  tag). The universal seed for new cores.
- `cores/v1/` — the current evolved 5-stage in-order with M-ext.

**Running the orchestrator on a core:**
```bash
make loop TARGET=v1 N=10                        # iterate v1 ten times
make next TARGET=v1                             # one round
make report TARGET=v1                           # per-core summary
```

**Creating a new core (Model A — branch + worktree):**
```bash
# 1. Create a feature branch for the new core.
git checkout -b core-nicebrev

# 2. (Optional) Create a separate working directory if you want to keep
#    your main checkout free for other cores in parallel.
git worktree add ../auto-arch-nicebrev core-nicebrev
cd ../auto-arch-nicebrev

# 3. Run the loop with BASE= to fork from an existing core.
make loop TARGET=nicebrev BASE=baseline N=20

# 4. When the experiment is done, push the branch and open a PR to main.
git push -u origin core-nicebrev
gh pr create
```

The orchestrator does NOT manage branches — that's all manual. This is
intentional: it lets you parallelize multiple cores via `git worktree add` and
review each core's evolution as a single PR diff.

**Per-core artifacts** (under `cores/<name>/`):
- `rtl/*.sv` — the design.
- `test/test_*.py` — cocotb tests for this core.
- `core.yaml` — declared targets + auto-updated `current:`.
- `CORE_PHILOSOPHY.md` — optional architect's intent (injected into agent prompts).
- `experiments/log.jsonl` — per-iteration outcomes.
- `experiments/progress.png` — fitness chart over time.
````

- [ ] **Step 3: Verify README renders correctly**

Run: `head -200 README.md` (or open in a markdown previewer)
Expected: clean rendering, no broken links.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add Multiple cores section with Model A workflow

Documents cores/baseline + cores/v1, TARGET= and BASE= flags, and the
git worktree pattern for parallel core development. Phase C of
multi-core layout refactor."
```

---

## Final verification

- [ ] **Step 1: Full sweep on v1**

```bash
make lint TARGET=v1
make test TARGET=v1
make cosim TARGET=v1
make formal TARGET=v1
make fpga TARGET=v1
```
All exit 0.

- [ ] **Step 2: Full sweep on baseline**

```bash
make lint TARGET=baseline
make cosim TARGET=baseline
make formal TARGET=baseline
make fpga TARGET=baseline
```
All exit 0.

- [ ] **Step 3: One-iteration smoke on v1**

```bash
make loop TARGET=v1 N=1
```
Expected: round completes (improvement or regression), log + plot updated, `cores/v1/core.yaml current:` refreshed.

- [ ] **Step 4: Fork-and-run smoke on a fresh core**

```bash
make loop TARGET=tmp-smoke BASE=baseline N=1
ls cores/tmp-smoke/
cat cores/tmp-smoke/core.yaml
```
Expected: new core created with all artifacts, baseline retest + 1 iteration logged.

Cleanup:
```bash
git rm -r cores/tmp-smoke
git commit -m "test: clean up smoke-test fork"
```

- [ ] **Step 5: Verify error messages**

```bash
make lint                            # → "TARGET= required. Available cores: baseline v1"
python3 -m tools.orchestrator -h     # → --target shown as required, --base shown as optional
make loop TARGET=nonexistent N=1     # → forks from baseline (because cores/nonexistent doesn't exist)
make loop TARGET=v1 BASE=baseline    # → "cores/v1/ already exists. Drop BASE= to continue ..."
```

- [ ] **Step 6: Final commit (if anything stray)**

`git status` should be clean. If not, investigate before declaring done.

---

## Self-review notes

- **Spec coverage:** Every section of `docs/superpowers/specs/2026-04-29-multi-core-layout-design.md` is covered: layout (Tasks 10, 11), orchestrator semantics (Tasks 9, 15, 16), CORE_PHILOSOPHY.md (Tasks 16, 18), core.yaml (Tasks 11, 17), harness changes (Tasks 1-9, 14), migration (Tasks 10, 11, 19), open questions noted as future work in the spec (no tasks needed).
- **Phase A safety:** Tasks 1-9 each leave the system in a working state (defaults preserve `rtl/`). Tested individually with `make` commands.
- **Phase B fragility window:** Between Task 10 (file move) and Task 12 (Makefile TARGET= plumbing), `make X` without TARGET= breaks. Task 12 fixes it. Run Task 12 immediately after Task 11.
- **Phase C correctness gates:** Task 13 verifies both cores under the new layout before Task 14 drops the fallback. Task 14 dropping the fallback is the point of no return — confirm Task 13 passes before committing Task 14.
- **Risk: `formal/riscv-formal/cores/<TARGET>/`.** This is the riscv-formal staging dir (separate from our `cores/`). Two parallel cores running formal will collide unless this is per-target — already addressed by `CORE_NAME` env var in Task 1.
- **Risk: macOS `tar` quirks.** Task 11 uses `git archive | tar -x` which can be finicky on macOS BSD tar. Fallback: per-file `git show baseline:rtl/<file> > cores/baseline/rtl/<file>`.
- **Risk: emit_verilog in orchestrator.py.** Task 9 mentions threading target through `emit_verilog`. If missed, Phase B breaks because `emit_verilog` still calls `verilator ... rtl/*.sv`. Confirm in Task 9 step 3 by reading `emit_verilog` and following the threading.
