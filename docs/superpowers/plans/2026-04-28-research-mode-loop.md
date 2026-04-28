# Research-mode Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `BRANCH`, `BASELINE`, `COREMARK`, and `LUT` knobs to `make loop` so a research run can target a sandbox branch, fork RTL from any historical commit, and accept hypotheses against a dual-target Pareto rule with auto-injected agent context.

**Architecture:** Pure-function accept rule in a new `tools/accept_rule.py` (easy to unit-test); `plot.py` parameterized on log/out paths; `worktree.py` parameterized on base/target branch; `hypothesis.py` augments its prompt with targets when set; `orchestrator.py` adds CLI args, branch lifecycle (create/check + first-iteration baseline retest), per-branch log/plot, and threads the run-config to its collaborators. Default-flag invocation (`make loop N=10 K=3`) is byte-identical to today's behavior.

**Tech Stack:** Python 3.11+, `argparse`, `subprocess`, `pytest`, `jsonschema`, `pyyaml`, `matplotlib`. Spec at `docs/superpowers/specs/2026-04-28-research-mode-loop-design.md`.

---

## File Structure

| File | Role |
|------|------|
| `tools/accept_rule.py` (new) | Pure functions: `score()`, `both_met()`, `accept()`. Two-phase Pareto and single-axis aspiration. |
| `tools/test_accept_rule.py` (new) | Unit tests covering phase 1, phase 2, single-axis, no-target. Uses the worked examples from the spec. |
| `tools/plot.py` | `plot_progress(log_path=…, out_path=…)` becomes parameterized; module-level defaults preserved for back-compat. |
| `tools/worktree.py` | `create_worktree(hyp_id, base_branch="main")` and `accept_worktree(hyp_id, msg, target_branch="main")` gain optional branch params. |
| `tools/agents/hypothesis.py` | `_build_prompt` and `run_hypothesis_agent` accept `targets=None, current_state=None`; inject "Optimization targets" block when set. |
| `tools/agents/test_hypothesis.py` (new) | Asserts the prompt contains the targets block when targets are passed, and *doesn't* contain it when they're not. |
| `tools/tournament.py` | `pick_winner` becomes target-aware via the accept-rule module; `run_slot` and `run_tournament_round` pass targets through. |
| `tools/test_tournament.py` | New tests for target-aware `pick_winner`. Existing tests stay green. |
| `tools/orchestrator.py` | New CLI args; flag-combination validation; branch create + checkout + first-iteration retest; per-branch `LOG_PATH`/`OUT_PATH`. |
| `Makefile` | New pass-through vars (`BRANCH`, `BASELINE`, `COREMARK`, `LUT`); forward to orchestrator CLI. |

---

## Task 1: Pure accept-rule module + tests

**Files:**
- Create: `tools/accept_rule.py`
- Create: `tools/test_accept_rule.py`

- [ ] **Step 1: Write the failing test file**

Create `tools/test_accept_rule.py`:

```python
"""Tests for the dual-target Pareto accept rule.
Cases mirror the worked examples in
docs/superpowers/specs/2026-04-28-research-mode-loop-design.md.
"""
from tools.accept_rule import score, both_met, accept


# ── score() — saturating deficit per axis ──────────────────────────────────
def test_score_below_both_targets():
    # Targets 300, 3000. Design (200, 5000):
    #   deficit_perf = (200 - 300) / 300 = -0.333...
    #   deficit_area = (3000 - 5000) / 3000 = -0.666...
    s = score(200, 5000, 300, 3000)
    assert abs(s - (-1.0)) < 1e-6


def test_score_perf_above_target_saturates_to_zero():
    # 600 perf is past the 300 target; deficit_perf saturates to 0.
    # Area still under-target contributes its share.
    s = score(600, 4000, 300, 3000)
    assert abs(s - (-1/3)) < 1e-6


def test_score_both_met_is_zero():
    s = score(320, 2900, 300, 3000)
    assert s == 0.0


def test_score_single_axis_perf():
    # No LUT target → only the perf axis contributes.
    s = score(200, None, 300, None)
    assert abs(s - (-1/3)) < 1e-6


def test_score_no_targets_is_zero():
    # No targets → degenerate to today's "ignore deficit" baseline.
    assert score(200, 5000, None, None) == 0.0


# ── both_met() — phase boundary ────────────────────────────────────────────
def test_both_met_true_at_or_past_targets():
    assert both_met(300, 3000, 300, 3000) is True
    assert both_met(400, 2500, 300, 3000) is True


def test_both_met_false_when_either_axis_short():
    assert both_met(299, 3000, 300, 3000) is False
    assert both_met(300, 3001, 300, 3000) is False


def test_both_met_only_with_dual_targets():
    # Single-axis targets → "both met" is undefined; return False so the
    # accept rule falls through to the single-axis path.
    assert both_met(400, 2000, 300, None) is False


# ── accept() — phase 1 ────────────────────────────────────────────────────
def test_accept_phase1_recovers_perf_at_area_cost_when_far_from_target():
    # Spec example 1: (200, 5000) → (290, 5500).
    # Old score = -1.000, new = -0.867 → accept.
    assert accept(old=(200, 5000), new=(290, 5500),
                  coremark_target=300, lut_target=3000) is True


def test_accept_phase1_rejects_paying_area_for_past_target_perf():
    # Spec example 2: (330, 3300) → (600, 4000).
    # perf already past target → free credit; area got worse → score drops.
    assert accept(old=(330, 3300), new=(600, 4000),
                  coremark_target=300, lut_target=3000) is False


def test_accept_phase1_accepts_hitting_area_target_with_small_perf_loss():
    # (310, 3300) → (290, 3000). Hits area target; small perf cost.
    assert accept(old=(310, 3300), new=(290, 3000),
                  coremark_target=300, lut_target=3000) is True


# ── accept() — phase 2 (both already at/past target) ──────────────────────
def test_accept_phase2_accepts_strict_pareto_perf_only():
    assert accept(old=(320, 2900), new=(340, 2900),
                  coremark_target=300, lut_target=3000) is True


def test_accept_phase2_accepts_strict_pareto_area_only():
    assert accept(old=(320, 2900), new=(320, 2700),
                  coremark_target=300, lut_target=3000) is True


def test_accept_phase2_rejects_perf_paid_with_area():
    assert accept(old=(320, 2900), new=(340, 2950),
                  coremark_target=300, lut_target=3000) is False


def test_accept_phase2_rejects_no_change():
    assert accept(old=(320, 2900), new=(320, 2900),
                  coremark_target=300, lut_target=3000) is False


def test_accept_phase2_to_phase1_regression_rejected():
    # (320, 2900) is phase 2. (350, 3050) regresses past area target →
    # phase 1 with negative score → reject.
    assert accept(old=(320, 2900), new=(350, 3050),
                  coremark_target=300, lut_target=3000) is False


# ── accept() — single-axis aspiration ─────────────────────────────────────
def test_accept_single_axis_below_target_must_close_deficit():
    # Target 370. Old 200 (deficit -.46), new 280 (deficit -.243). Accept.
    assert accept(old=(200, None), new=(280, None),
                  coremark_target=370, lut_target=None) is True


def test_accept_single_axis_above_target_max_coremark():
    # Both past target → fall through to plain "fitness > champion".
    assert accept(old=(380, None), new=(400, None),
                  coremark_target=370, lut_target=None) is True
    assert accept(old=(400, None), new=(380, None),
                  coremark_target=370, lut_target=None) is False


def test_accept_single_axis_regression_below_target_rejected():
    # 380 → 350: 380 was past target (score 0); 350 is below (score -0.054).
    assert accept(old=(380, None), new=(350, None),
                  coremark_target=370, lut_target=None) is False


# ── accept() — no targets (today's behavior) ──────────────────────────────
def test_accept_no_targets_pure_fitness_compare():
    assert accept(old=(300, 5000), new=(310, 5500),
                  coremark_target=None, lut_target=None) is True
    assert accept(old=(310, 5500), new=(300, 5000),
                  coremark_target=None, lut_target=None) is False


def test_accept_no_targets_equal_fitness_rejected():
    assert accept(old=(300, 5000), new=(300, 4000),
                  coremark_target=None, lut_target=None) is False
```

- [ ] **Step 2: Run the test to confirm it fails for the right reason**

Run: `python3 -m pytest tools/test_accept_rule.py -v`
Expected: collection failure or `ModuleNotFoundError: No module named 'tools.accept_rule'`.

- [ ] **Step 3: Write the minimal implementation**

Create `tools/accept_rule.py`:

```python
"""Two-phase Pareto accept rule for the research-mode loop.

Spec: docs/superpowers/specs/2026-04-28-research-mode-loop-design.md.

Pure functions, no I/O. Designed to be unit-testable without subprocess
or git state. The orchestrator calls accept(old, new, targets) when
deciding whether to merge a hypothesis into the active branch.
"""
from typing import Optional


def _deficit(value: float, target: float, lower_is_better: bool) -> float:
    """Saturating deficit: 0 when value is at-or-past target, negative below.

    For 'higher is better' axes (perf): deficit = min(0, (value - target)/target).
    For 'lower is better' axes (area): deficit = min(0, (target - value)/target).
    """
    if target is None:
        return 0.0
    if lower_is_better:
        raw = (target - value) / target
    else:
        raw = (value - target) / target
    return min(0.0, raw)


def score(perf: Optional[float],
          lut: Optional[float],
          coremark_target: Optional[float],
          lut_target: Optional[float]) -> float:
    """Sum of saturating deficits across the active axes.

    An axis with target=None contributes 0 (axis is unconstrained).
    Result is always <= 0, with 0 meaning "all active axes at-or-past target".
    """
    s = 0.0
    if coremark_target is not None and perf is not None:
        s += _deficit(perf, coremark_target, lower_is_better=False)
    if lut_target is not None and lut is not None:
        s += _deficit(lut, lut_target, lower_is_better=True)
    return s


def both_met(perf: Optional[float],
             lut: Optional[float],
             coremark_target: Optional[float],
             lut_target: Optional[float]) -> bool:
    """True only when BOTH targets are set AND both axes are at/past their targets."""
    if coremark_target is None or lut_target is None:
        return False
    if perf is None or lut is None:
        return False
    return perf >= coremark_target and lut <= lut_target


def _strict_pareto(old, new) -> bool:
    """new strictly dominates old on (perf, lut)?

    Tuples are (perf, lut). Higher perf is better; lower lut is better.
    Strict dominance: at least as good on both, strictly better on one.
    """
    op, ol = old
    np, nl = new
    not_worse = (np >= op) and (nl <= ol)
    strictly_better = (np > op) or (nl < ol)
    return not_worse and strictly_better


def accept(old: tuple,
           new: tuple,
           coremark_target: Optional[float] = None,
           lut_target: Optional[float] = None) -> bool:
    """Accept rule. old/new are (perf, lut) tuples. Either component may be
    None when the corresponding axis is unconstrained.

    Three modes, dispatched by which targets are set:
      - No targets:    pure fitness comparison (today's behavior).
      - One target:    deficit while below; max-axis past target.
      - Two targets:   phase-1 deficit, phase-2 strict Pareto.
    """
    op, ol = old
    np, nl = new

    # No targets → today's behavior (just compare CoreMark).
    if coremark_target is None and lut_target is None:
        return (np or 0) > (op or 0)

    s_old = score(op, ol, coremark_target, lut_target)
    s_new = score(np, nl, coremark_target, lut_target)

    # Phase 1: at least one axis still below target → score must improve.
    if s_new > s_old:
        return True

    # Tie at score=0 with both targets met → strict Pareto on (perf, lut).
    if (s_old == 0.0 and s_new == 0.0
            and both_met(op, ol, coremark_target, lut_target)
            and both_met(np, nl, coremark_target, lut_target)):
        return _strict_pareto((op, ol), (np, nl))

    # Tie at score=0 in single-axis mode (both past the one target) → fall
    # through to plain "improve the targeted axis".
    if (s_old == 0.0 and s_new == 0.0):
        if coremark_target is not None and lut_target is None:
            return (np or 0) > (op or 0)
        if lut_target is not None and coremark_target is None:
            return (nl or 0) < (ol or 0)

    return False
```

- [ ] **Step 4: Run tests until they all pass**

Run: `python3 -m pytest tools/test_accept_rule.py -v`
Expected: 18 passed.

- [ ] **Step 5: Commit**

```bash
git add tools/accept_rule.py tools/test_accept_rule.py
git commit -m "tools: pure two-phase Pareto accept rule + tests"
```

---

## Task 2: Parameterize plot.py on log/out paths

**Files:**
- Modify: `tools/plot.py`

- [ ] **Step 1: Read current plot.py**

Run: `cat tools/plot.py | head -25`
Note the module-level `LOG_PATH = Path("experiments/log.jsonl")` and `OUT_PATH = Path("experiments/progress.png")`.

- [ ] **Step 2: Refactor `plot_progress` signature and uses**

Replace the function declaration and the file I/O lines so callers can override paths. The full edit:

Find:
```python
LOG_PATH = Path("experiments/log.jsonl")
OUT_PATH = Path("experiments/progress.png")
```
…and:
```python
def plot_progress():
    if not LOG_PATH.exists():
        return

    entries = [json.loads(l) for l in LOG_PATH.read_text().splitlines() if l.strip()]
```
…and the final block:
```python
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(str(OUT_PATH), dpi=150)
    plt.close(fig)
```

Replace with:
```python
LOG_PATH = Path("experiments/log.jsonl")
OUT_PATH = Path("experiments/progress.png")
```
(unchanged) and:
```python
def plot_progress(log_path: Path | None = None, out_path: Path | None = None):
    log_path = log_path or LOG_PATH
    out_path = out_path or OUT_PATH
    if not log_path.exists():
        return

    entries = [json.loads(l) for l in log_path.read_text().splitlines() if l.strip()]
```
…and:
```python
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(str(out_path), dpi=150)
    plt.close(fig)
```

(I.e. add the two `Path | None` parameters with `... or DEFAULT` resolution at the top, then thread `log_path`/`out_path` through every place the old constants were referenced inside the function.)

- [ ] **Step 3: Run plot.py with the default to confirm no regression**

Run: `python3 -m tools.plot && file experiments/progress.png`
Expected: PNG file regenerated, ~280 KB, no errors.

- [ ] **Step 4: Run plot.py against a tmp log to confirm parameterization works**

Run:
```bash
mkdir -p /tmp/plot-test/experiments
echo '{"id":"t","outcome":"improvement","fitness":300,"lut4":5000}' \
    > /tmp/plot-test/experiments/log.jsonl
python3 -c "
from pathlib import Path
from tools.plot import plot_progress
plot_progress(log_path=Path('/tmp/plot-test/experiments/log.jsonl'),
              out_path=Path('/tmp/plot-test/experiments/progress.png'))
"
ls -la /tmp/plot-test/experiments/progress.png
```
Expected: `progress.png` created in `/tmp/plot-test/experiments/`.

- [ ] **Step 5: Commit**

```bash
git add tools/plot.py
git commit -m "plot: accept log_path/out_path overrides for per-branch outputs"
```

---

## Task 3: Worktree branch routing

**Files:**
- Modify: `tools/worktree.py`

- [ ] **Step 1: Replace the worktree functions to take branch params**

Replace the contents of `tools/worktree.py` with:

```python
"""Git worktree lifecycle management.

Worktrees are forked off the loop's *active* branch (default: main) and
merged back into that same branch on accept. The active branch is set
by the orchestrator at run start; functions here take it as a parameter
so the same module supports both the default `main` flow and sandbox
research branches without state.
"""
import subprocess, shutil
from pathlib import Path

WORKTREE_BASE = Path("experiments/worktrees")

def create_worktree(hypothesis_id: str, base_branch: str = "main") -> str:
    """Creates a git worktree at experiments/worktrees/<id>. Returns path.

    The new branch <hypothesis_id> is created from <base_branch>'s tip,
    so accepted hypotheses chain on the active branch (whether that is
    main or a sandbox research branch).

    Also symlinks the (gitignored) formal/riscv-formal/ tree into the
    worktree so `make formal` works without a fresh ~200 MiB clone per
    iteration.
    """
    WORKTREE_BASE.mkdir(parents=True, exist_ok=True)
    path = str((WORKTREE_BASE / hypothesis_id).resolve())
    subprocess.run(
        ["git", "worktree", "add", "-b", hypothesis_id, path, base_branch],
        check=True
    )

    main_riscv_formal = Path("formal/riscv-formal").resolve()
    if main_riscv_formal.exists():
        wt_riscv_formal = Path(path) / "formal" / "riscv-formal"
        wt_riscv_formal.parent.mkdir(parents=True, exist_ok=True)
        if not wt_riscv_formal.exists():
            wt_riscv_formal.symlink_to(main_riscv_formal)

    return path

def accept_worktree(hypothesis_id: str,
                    commit_message: str,
                    target_branch: str = "main"):
    """Merges worktree branch into target_branch and removes the worktree.

    Caller is responsible for ensuring target_branch is the active branch
    of the orchestrator's run. We `git checkout target_branch` first
    (idempotent if already on it), then ff-merge the worktree branch.
    """
    path = str((WORKTREE_BASE / hypothesis_id).resolve())
    # Commit any uncommitted changes in worktree. Stage exactly the
    # paths the agent is permitted to modify (rtl/ + test/test_*.py).
    subprocess.run(["git", "-C", path, "add", "-A", "rtl/"], check=True)
    test_changes = subprocess.run(
        ["git", "-C", path, "ls-files", "--modified", "--others", "--exclude-standard",
         "test/test_*.py"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    if test_changes:
        subprocess.run(["git", "-C", path, "add", "--"] + test_changes, check=True)
    subprocess.run(
        ["git", "-C", path, "commit", "--allow-empty", "-m", commit_message],
        check=True
    )

    # Merge into the active branch. Idempotent checkout — no-op if already on it.
    subprocess.run(["git", "checkout", target_branch], check=True)
    subprocess.run(
        ["git", "merge", "--ff-only", hypothesis_id],
        check=True
    )
    destroy_worktree(hypothesis_id)

def destroy_worktree(hypothesis_id: str):
    """Removes worktree and deletes the branch."""
    path = str((WORKTREE_BASE / hypothesis_id).resolve())
    subprocess.run(["git", "worktree", "remove", "--force", path], check=False)
    subprocess.run(["git", "branch", "-D", hypothesis_id], check=False)
    shutil.rmtree(path, ignore_errors=True)
```

- [ ] **Step 2: Run existing cocotb suite to confirm no Python import regressions**

Run: `python3 -c "from tools.worktree import create_worktree, accept_worktree, destroy_worktree; print('imports ok')"`
Expected: `imports ok`.

- [ ] **Step 3: Smoke-test create + destroy on a real branch**

Run:
```bash
git branch tmp-worktree-smoke main
python3 -c "
from tools.worktree import create_worktree, destroy_worktree
p = create_worktree('hyp-smoke-1', base_branch='tmp-worktree-smoke')
print('created at', p)
destroy_worktree('hyp-smoke-1')
print('destroyed')
"
git branch -D tmp-worktree-smoke
```
Expected: created/destroyed messages, no errors, no leftover branches in `git branch`.

- [ ] **Step 4: Commit**

```bash
git add tools/worktree.py
git commit -m "worktree: parameterize on base_branch / target_branch for sandbox runs"
```

---

## Task 4: Hypothesis prompt — auto-injected targets block

**Files:**
- Modify: `tools/agents/hypothesis.py`
- Create: `tools/agents/test_hypothesis.py`

- [ ] **Step 1: Add `targets` and `current_state` params to `_build_prompt`**

Find the function signature in `tools/agents/hypothesis.py`:
```python
def _build_prompt(log_tail: list, current_fitness: float, baseline_fitness: float,
                  hyp_id: str | None = None,
                  category_hint: str | None = None) -> str:
```

Replace with:
```python
def _build_prompt(log_tail: list, current_fitness: float, baseline_fitness: float,
                  hyp_id: str | None = None,
                  category_hint: str | None = None,
                  targets: dict | None = None,
                  current_state: dict | None = None) -> str:
```

Then, immediately before the function's `return f"""You are…"""` literal, build the targets block:
```python
    targets_clause = _targets_clause(targets, current_state) if targets else ""
```

…and inject `{targets_clause}` into the existing prompt template, right after the `category_clause` interpolation. (Today's prompt template starts with the `You are a CPU…` heading; place `{targets_clause}` after the existing optional clauses and before the architecture dump.)

Add the new helper at module scope, just above `_build_prompt`:

```python
def _targets_clause(targets: dict, current_state: dict | None) -> str:
    """Generate the 'Optimization targets' prompt block.

    `targets` is a dict like {"coremark": 300, "lut": 3000}; either key
    may be missing for single-axis mode. `current_state` mirrors the
    same keys with the active branch's champion values.
    """
    from tools.accept_rule import score, both_met
    cs = current_state or {}
    ct = targets.get("coremark")
    lt = targets.get("lut")
    cur_perf = cs.get("coremark")
    cur_lut  = cs.get("lut")
    s = score(cur_perf, cur_lut, ct, lt)
    parts = ["## Optimization targets", ""]
    parts.append("This research run targets:")
    if ct is not None:
        parts.append(f"  CoreMark = {ct} iter/s")
    if lt is not None:
        parts.append(f"  LUT4     = {lt}")
    parts.append("")
    parts.append("Current state:")
    if ct is not None and cur_perf is not None:
        status = "target met" if cur_perf >= ct else f"{(ct - cur_perf)/ct*100:.1f}% below target"
        parts.append(f"  CoreMark   = {cur_perf} iter/s   ({status})")
    if lt is not None and cur_lut is not None:
        status = "target met" if cur_lut <= lt else f"{(cur_lut - lt)/lt*100:.1f}% above target"
        parts.append(f"  LUT4       = {cur_lut}           ({status})")
    parts.append(f"  combined score = {s:+.3f}")
    parts.append("")
    if ct is not None and lt is not None:
        parts.append("Accept rule: deficit-driven in phase 1 (any axis below target);")
        parts.append("strict Pareto-dominance in phase 2 (both at target).")
        parts.append("")
        parts.append("Your hypothesis should attack whichever axis is currently failing.")
        parts.append("If both targets are met, find a 'free win' that strictly dominates")
        parts.append("the current design on at least one axis without regressing the other.")
    elif ct is not None:
        parts.append("Accept rule: pull CoreMark toward the target while below; once past")
        parts.append("the target, any CoreMark improvement lands.")
    else:
        parts.append("Accept rule: pull LUT4 toward the target while above; once at/under")
        parts.append("the target, any LUT4 reduction lands.")
    return "\n".join(parts) + "\n\n"
```

- [ ] **Step 2: Update `run_hypothesis_agent` to thread targets through**

Find `run_hypothesis_agent` in `tools/agents/hypothesis.py`. Add the same two new optional params and forward them to `_build_prompt`:

```python
def run_hypothesis_agent(log_tail, current_fitness, baseline_fitness,
                         hyp_id=None, allowed_yaml_ids=None, category_hint=None,
                         targets=None, current_state=None):
    ...
    prompt = _build_prompt(log_tail, current_fitness, baseline_fitness,
                           hyp_id=hyp_id, category_hint=category_hint,
                           targets=targets, current_state=current_state)
    ...
```

(Find the existing `_build_prompt(...)` call inside `run_hypothesis_agent` and add the two new keyword arguments.)

- [ ] **Step 3: Write the test file**

Create `tools/agents/test_hypothesis.py`:

```python
"""Tests for hypothesis-prompt augmentation in research mode."""
from tools.agents.hypothesis import _build_prompt


def _stub_args():
    """Minimum args _build_prompt needs to run."""
    return dict(
        log_tail=[],
        current_fitness=300.0,
        baseline_fitness=300.0,
        hyp_id="hyp-test-001-r1s0",
    )


def test_prompt_omits_targets_block_when_no_targets():
    p = _build_prompt(**_stub_args())
    assert "Optimization targets" not in p


def test_prompt_includes_dual_target_block():
    p = _build_prompt(
        **_stub_args(),
        targets={"coremark": 300, "lut": 3000},
        current_state={"coremark": 320, "lut": 3300},
    )
    assert "Optimization targets" in p
    assert "CoreMark = 300 iter/s" in p
    assert "LUT4     = 3000" in p
    assert "CoreMark   = 320 iter/s" in p
    assert "LUT4       = 3300" in p
    assert "deficit-driven in phase 1" in p
    assert "strict Pareto-dominance in phase 2" in p


def test_prompt_includes_single_target_perf_block():
    p = _build_prompt(
        **_stub_args(),
        targets={"coremark": 370},
        current_state={"coremark": 320},
    )
    assert "Optimization targets" in p
    assert "CoreMark = 370 iter/s" in p
    assert "LUT4" not in p.split("Optimization targets")[1].split("Accept rule")[0]
    assert "pull CoreMark toward the target" in p


def test_prompt_target_met_status_when_above():
    p = _build_prompt(
        **_stub_args(),
        targets={"coremark": 300, "lut": 3000},
        current_state={"coremark": 320, "lut": 2900},
    )
    assert "target met" in p
```

- [ ] **Step 4: Run tests until green**

Run: `python3 -m pytest tools/agents/test_hypothesis.py -v`
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add tools/agents/hypothesis.py tools/agents/test_hypothesis.py
git commit -m "hypothesis: auto-inject target + state context into prompt"
```

---

## Task 5: Tournament — wire the accept rule

**Files:**
- Modify: `tools/tournament.py`
- Modify: `tools/test_tournament.py`

- [ ] **Step 1: Replace `pick_winner` with a target-aware version**

Find:
```python
def pick_winner(entries: list[dict], current_best: float) -> Optional[dict]:
    """Return the round's winner: highest-fitness slot that beat current_best.
    ...
    """
    candidates = [
        e for e in entries
        if isinstance(e.get("fitness"), (int, float))
        and e["fitness"] > current_best
    ]
    if not candidates:
        return None
    return max(candidates, key=lambda e: (e["fitness"], -e["slot"]))
```

Replace with:
```python
def pick_winner(entries: list[dict],
                current_best: float,
                current_lut: float | None = None,
                coremark_target: float | None = None,
                lut_target: float | None = None) -> Optional[dict]:
    """Return the round's winner via the accept-rule module.

    With no targets set, behavior is identical to the legacy "highest
    fitness > current_best" rule. With targets set, accept() is called
    per-candidate with (perf, lut) tuples.

    Tie-break: among candidates that all pass accept, prefer the one
    that maximizes (fitness, -lut4, -slot). This degenerates to the
    legacy "highest fitness, lowest slot" tie-break when LUT is
    unconstrained.
    """
    from tools.accept_rule import accept

    valid = [e for e in entries
             if isinstance(e.get("fitness"), (int, float))]
    if not valid:
        return None

    old = (current_best, current_lut)

    candidates = []
    for e in valid:
        new = (e["fitness"], e.get("lut4"))
        if accept(old, new,
                  coremark_target=coremark_target, lut_target=lut_target):
            candidates.append(e)

    if not candidates:
        return None
    return max(candidates,
               key=lambda e: (e["fitness"], -(e.get("lut4") or 0), -e["slot"]))
```

- [ ] **Step 2: Add target-aware tests to `tools/test_tournament.py`**

Append (do not replace) to `tools/test_tournament.py`:

```python
# ── target-aware pick_winner ───────────────────────────────────────────────
def _entry(slot, fitness=None, lut4=None, outcome="regression"):
    return {"slot": slot, "fitness": fitness, "lut4": lut4, "outcome": outcome}


def test_pick_winner_no_targets_legacy_behavior():
    from tools.tournament import pick_winner
    entries = [_entry(0, 290), _entry(1, 320), _entry(2, 310)]
    w = pick_winner(entries, current_best=300)
    assert w["slot"] == 1


def test_pick_winner_dual_target_phase1():
    # Targets (300, 3000). Champion (200, 5000). Slot 0 closes both
    # deficits a bit; slot 1 adds LUT but no perf benefit.
    from tools.tournament import pick_winner
    entries = [
        _entry(0, fitness=290, lut4=4500),
        _entry(1, fitness=205, lut4=5500),
    ]
    w = pick_winner(entries, current_best=200, current_lut=5000,
                    coremark_target=300, lut_target=3000)
    assert w is not None and w["slot"] == 0


def test_pick_winner_dual_target_rejects_no_progress():
    # Phase 2 (both targets met). Slot 0 trades perf for LUT — strict Pareto
    # rejects. Slot 1 makes things worse on both axes.
    from tools.tournament import pick_winner
    entries = [
        _entry(0, fitness=340, lut4=2950),
        _entry(1, fitness=300, lut4=3000),
    ]
    w = pick_winner(entries, current_best=320, current_lut=2900,
                    coremark_target=300, lut_target=3000)
    assert w is None


def test_pick_winner_dual_target_phase2_strict_dominance():
    # Phase 2, slot 0 strictly dominates (perf up, lut down).
    from tools.tournament import pick_winner
    entries = [
        _entry(0, fitness=340, lut4=2800),
        _entry(1, fitness=320, lut4=2900),  # equal — fails strict
    ]
    w = pick_winner(entries, current_best=320, current_lut=2900,
                    coremark_target=300, lut_target=3000)
    assert w is not None and w["slot"] == 0
```

- [ ] **Step 3: Update `run_slot` and `run_tournament_round` signatures to thread targets**

In `tools/tournament.py`, add `targets: dict | None = None` and `current_lut: float | None = None` params:

Find `def run_slot(slot, hyp_id, allowed_yaml_ids, log_tail, current_best, baseline, fixed_hyp_path):` — replace with:
```python
def run_slot(
    slot: int,
    hyp_id: str,
    allowed_yaml_ids: list[str],
    log_tail: list,
    current_best: float,
    current_lut: float | None,
    baseline: float,
    fixed_hyp_path: str | None,
    targets: dict | None,
):
```

Inside, when calling `run_hypothesis_agent`, thread the new context:
Find:
```python
            hyp_path = run_hypothesis_agent(
                log_tail, current_best, baseline,
                hyp_id=hyp_id,
                allowed_yaml_ids=allowed_yaml_ids,
                category_hint=category,
            )
```
Replace with:
```python
            current_state = (
                {"coremark": current_best, "lut": current_lut}
                if (targets and current_best > 0) else None
            )
            hyp_path = run_hypothesis_agent(
                log_tail, current_best, baseline,
                hyp_id=hyp_id,
                allowed_yaml_ids=allowed_yaml_ids,
                category_hint=category,
                targets=targets,
                current_state=current_state,
            )
```

Find `def run_tournament_round(round_id, tournament_size, log, fixed_hyp_paths=None):` — replace with:
```python
def run_tournament_round(
    round_id: int,
    tournament_size: int,
    log: list,
    fixed_hyp_paths: list[str] | None = None,
    targets: dict | None = None,
    target_branch: str = "main",
):
```

Inside `run_tournament_round`, find `from tools.orchestrator import (current_best as _current_best, baseline_fitness as _baseline, append_log,)` — extend it to also import the lut helper:
```python
    from tools.orchestrator import (
        current_best as _current_best,
        current_lut as _current_lut,
        baseline_fitness as _baseline,
        append_log,
    )
```

Below the existing `best = _current_best(log)`, add:
```python
    cur_lut = _current_lut(log)
```

In the `pool.submit(run_slot, ...)` call, pass `cur_lut`, `targets` and use the new signature:
Find:
```python
            pool.submit(
                run_slot, slot, hyp_ids[slot], hyp_ids,
                log, best, baseline, fixed_hyp_paths[slot],
            ): slot
```
Replace with:
```python
            pool.submit(
                run_slot, slot, hyp_ids[slot], hyp_ids,
                log, best, cur_lut, baseline, fixed_hyp_paths[slot],
                targets,
            ): slot
```

In the winner-pick call, find:
```python
    winner = pick_winner(entries, current_best=best)
```
Replace with:
```python
    winner = pick_winner(
        entries,
        current_best=best,
        current_lut=cur_lut,
        coremark_target=(targets or {}).get("coremark"),
        lut_target=(targets or {}).get("lut"),
    )
```

In the `accept_worktree(entry['id'], msg)` call, find:
```python
                accept_worktree(entry['id'], msg)
```
Replace with:
```python
                accept_worktree(entry['id'], msg, target_branch=target_branch)
```

- [ ] **Step 4: Run tournament tests**

Run: `python3 -m pytest tools/test_tournament.py -v`
Expected: all existing + 4 new tests pass.

- [ ] **Step 5: Commit**

```bash
git add tools/tournament.py tools/test_tournament.py
git commit -m "tournament: target-aware pick_winner + thread targets through round"
```

---

## Task 6: Orchestrator — flags, branch lifecycle, per-branch artifacts

**Files:**
- Modify: `tools/orchestrator.py`

This is the biggest task. Sub-tasks: (a) helper functions for branch + lut lookup, (b) CLI args + validation, (c) branch lifecycle, (d) per-branch log/plot path wiring, (e) thread targets/branch into `run_tournament_round`.

- [ ] **Step 1: Add `current_lut` helper and a branch-resolution helper**

Find the block in `tools/orchestrator.py` defining `current_best` and `baseline_fitness`. Add `current_lut` next to them:

```python
def current_lut(log: list) -> float | None:
    """LUT4 of the latest accepted improvement. None if no improvements yet."""
    improvements = [e for e in log if e.get('outcome') == 'improvement']
    if not improvements:
        return None
    last = improvements[-1]
    val = last.get('lut4')
    return val if isinstance(val, (int, float)) else None
```

- [ ] **Step 2: Add a small branch-lifecycle helper module-level function**

Above `def main():`, add:

```python
def _resolve_ref(ref: str) -> str:
    """git rev-parse <ref> -> SHA, or raise SystemExit with a clear message."""
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--verify", ref],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.strip()
    except subprocess.CalledProcessError:
        raise SystemExit(f"BASELINE: cannot resolve git ref '{ref}'.")


def _branch_exists(name: str) -> bool:
    return subprocess.run(
        ["git", "rev-parse", "--verify", f"refs/heads/{name}"],
        capture_output=True,
    ).returncode == 0


def _ensure_branch(branch: str, baseline: str | None) -> bool:
    """Create branch from baseline (or main) if missing; error if both branch
    and baseline are set and the branch already exists. Returns True iff the
    branch was newly created (caller uses this to decide whether to run a
    baseline retest)."""
    exists = _branch_exists(branch)
    if exists and baseline is not None:
        raise SystemExit(
            f"Branch '{branch}' already exists. To start fresh from "
            f"'{baseline}', run `git branch -D {branch}` first."
        )
    if not exists:
        ref = baseline or "main"
        sha = _resolve_ref(ref)
        subprocess.run(["git", "branch", branch, sha], check=True)
        return True
    return False
```

- [ ] **Step 3: Make `LOG_PATH` and the plot output path per-run**

Find at the top of `tools/orchestrator.py`:
```python
LOG_PATH      = Path("experiments/log.jsonl")
HYP_SCHEMA    = json.loads(Path("schemas/hypothesis.schema.json").read_text())
RESULT_SCHEMA = json.loads(Path("schemas/eval_result.schema.json").read_text())
```

Add the plot path constant alongside it:
```python
LOG_PATH       = Path("experiments/log.jsonl")
PLOT_PATH      = Path("experiments/progress.png")
HYP_SCHEMA     = json.loads(Path("schemas/hypothesis.schema.json").read_text())
RESULT_SCHEMA  = json.loads(Path("schemas/eval_result.schema.json").read_text())
```

Then find `append_log`. Replace its `plot_progress()` and `Path("experiments/progress.png")` references with the module globals so `main()` can swap them:

Find:
```python
        plot_progress()
        # Commit log + plot together. ...
        subprocess.run(["git", "add", str(LOG_PATH)], check=True)
        plot_path = Path("experiments/progress.png")
        if plot_path.exists():
            subprocess.run(["git", "add", str(plot_path)], check=True)
```

Replace with:
```python
        plot_progress(log_path=LOG_PATH, out_path=PLOT_PATH)
        # Commit log + plot together. ...
        subprocess.run(["git", "add", str(LOG_PATH)], check=True)
        if PLOT_PATH.exists():
            subprocess.run(["git", "add", str(PLOT_PATH)], check=True)
```

- [ ] **Step 4: Add CLI args, flag validation, branch lifecycle, and target wiring to `main()`**

Replace `main()` end-to-end with:

```python
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--iterations', type=int, default=1,
                        help='Number of tournament rounds to run.')
    parser.add_argument('--tournament-size', type=int, default=3,
                        help='Number of parallel slots per round (N=1 = sequential).')
    parser.add_argument('--report', action='store_true')
    parser.add_argument('--from-hypothesis', metavar='PATH', default=None,
                        help='Skip the LLM hypothesis step and use a pre-written YAML. '
                             'Comma-separated list for tournament-size > 1.')
    parser.add_argument('--branch', default=None,
                        help='Sandbox merge target. Default: main.')
    parser.add_argument('--baseline', default=None,
                        help='Git ref for fresh-branch RTL fork. Default: main. '
                             'Requires --branch.')
    parser.add_argument('--coremark-target', type=int, default=None,
                        help='CoreMark iter/s target for two-phase Pareto accept.')
    parser.add_argument('--lut-target', type=int, default=None,
                        help='LUT4 target for two-phase Pareto accept.')
    args = parser.parse_args()

    # Flag validation.
    if args.baseline and not args.branch:
        raise SystemExit("--baseline requires --branch.")
    if args.coremark_target is not None and args.coremark_target <= 0:
        raise SystemExit("--coremark-target must be positive.")
    if args.lut_target is not None and args.lut_target <= 0:
        raise SystemExit("--lut-target must be positive.")

    if args.report:
        run_report()
        return

    targets = {}
    if args.coremark_target is not None:
        targets["coremark"] = args.coremark_target
    if args.lut_target is not None:
        targets["lut"] = args.lut_target

    # Per-branch log/plot. Default branch (no --branch) keeps writing
    # to experiments/log.jsonl + experiments/progress.png.
    target_branch = args.branch or "main"
    if args.branch:
        global LOG_PATH, PLOT_PATH
        LOG_PATH  = Path(f"experiments/log-{args.branch}.jsonl")
        PLOT_PATH = Path(f"experiments/progress-{args.branch}.png")

    # Branch lifecycle.
    fresh_branch = False
    if args.branch:
        fresh_branch = _ensure_branch(args.branch, args.baseline)
        subprocess.run(["git", "checkout", args.branch], check=True)

    # First-iteration baseline retest on fresh branches.
    if fresh_branch:
        print(f"[orchestrator] fresh branch '{args.branch}' — running baseline retest",
              flush=True)
        _run_baseline_retest(args.branch)

    fixed = None
    if args.from_hypothesis:
        fixed = [p.strip() for p in args.from_hypothesis.split(',')]

    # Round numbering.
    log = read_log()
    prior_rounds = [e.get('round_id', 0) for e in log if isinstance(e.get('round_id'), int)]
    next_round = (max(prior_rounds) + 1) if prior_rounds else 1

    for r in range(args.iterations):
        round_id = next_round + r
        log = read_log()
        run_tournament_round(
            round_id, args.tournament_size, log,
            fixed_hyp_paths=fixed,
            targets=targets or None,
            target_branch=target_branch,
        )
```

- [ ] **Step 5: Add `_run_baseline_retest` to the orchestrator**

Above `def main():`, add:

```python
def _run_baseline_retest(branch: str):
    """Run a one-shot eval on the freshly created branch's RTL.

    Writes a single 'baseline' entry to the per-branch log so subsequent
    hypothesis rounds have a fitness anchor. Aborts the run if any gate
    fails — the user investigates while the branch is left intact.
    """
    from tools.eval.formal import run_formal
    from tools.eval.cosim import run_cosim
    from tools.eval.fpga import run_fpga_eval

    # Re-emit verilog + run gates against the main repo's working copy
    # (the active branch is checked out). We don't create a worktree —
    # the baseline retest IS the branch tip, not a hypothesis.
    repo_root = str(Path(".").resolve())
    if not emit_verilog(repo_root):
        raise SystemExit(f"baseline retest: emit_verilog failed on '{branch}'.")
    formal = run_formal(repo_root)
    if not formal['passed']:
        raise SystemExit(
            f"baseline retest: formal failed on '{branch}': "
            f"{formal.get('failed_check','')}"
        )
    cosim = run_cosim(repo_root)
    if not cosim['passed']:
        raise SystemExit(
            f"baseline retest: cosim failed on '{branch}': "
            f"{cosim.get('failed_elf','')}"
        )
    fpga = run_fpga_eval(repo_root)
    if fpga.get('placement_failed') or fpga.get('bench_failed'):
        raise SystemExit(f"baseline retest: fpga eval failed on '{branch}'.")

    sha = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    entry = {
        'id':            f'baseline-{branch}-{sha}',
        'title':         f'Baseline retest for branch {branch}',
        'category':      'micro_opt',
        'outcome':       'improvement',
        'fitness':       fpga['fitness'],
        'delta_pct':     0.0,
        'vs_baseline':   0.0,
        'fmax_mhz':      fpga['fmax_mhz'],
        'ipc_coremark':  fpga['ipc_coremark'],
        'cycles':        fpga.get('cycles'),
        'iterations':    fpga.get('iterations'),
        'lut4':          fpga['lut4'],
        'ff':            fpga['ff'],
        'seeds':         fpga['seeds'],
        'formal_passed': True,
        'cosim_passed':  True,
        'error':         None,
        'implementation_notes': '',
        'timestamp':     datetime.datetime.utcnow().isoformat(),
        'round_id':      0,
        'slot':          0,
    }
    append_log(entry)
```

- [ ] **Step 6: Smoke-test orchestrator imports**

Run: `python3 -c "from tools.orchestrator import main, current_lut, _ensure_branch, _resolve_ref, _run_baseline_retest; print('imports ok')"`
Expected: `imports ok`.

- [ ] **Step 7: Smoke-test flag validation**

Run: `python3 -m tools.orchestrator --baseline=main 2>&1 | tail -3`
Expected: `--baseline requires --branch.`

Run: `python3 -m tools.orchestrator --coremark-target=-5 --branch=foo 2>&1 | tail -3`
Expected: `--coremark-target must be positive.`

- [ ] **Step 8: Run all tests**

Run: `python3 -m pytest tools/ -v`
Expected: all green (existing + Task 1 + Task 4 + Task 5 tests).

- [ ] **Step 9: Commit**

```bash
git add tools/orchestrator.py
git commit -m "orchestrator: BRANCH/BASELINE/COREMARK/LUT flags + per-branch artifacts + baseline retest"
```

---

## Task 7: Makefile pass-through

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Extend the orchestrator-knobs block at the top of the file**

Find:
```makefile
N     ?= 10
K     ?= 1
AGENT ?= $(or $(AGENT_PROVIDER),codex)
```

Replace with:
```makefile
N        ?= 10
K        ?= 1
AGENT    ?= $(or $(AGENT_PROVIDER),codex)
BRANCH   ?=
BASELINE ?=
COREMARK ?=
LUT      ?=

# Compose optional CLI flags for the orchestrator. Empty vars produce
# empty strings so the orchestrator falls back to its defaults.
ORCH_FLAGS  = --iterations $(N) --tournament-size $(K)
ifneq ($(strip $(BRANCH)),)
  ORCH_FLAGS += --branch $(BRANCH)
endif
ifneq ($(strip $(BASELINE)),)
  ORCH_FLAGS += --baseline $(BASELINE)
endif
ifneq ($(strip $(COREMARK)),)
  ORCH_FLAGS += --coremark-target $(COREMARK)
endif
ifneq ($(strip $(LUT)),)
  ORCH_FLAGS += --lut-target $(LUT)
endif
```

- [ ] **Step 2: Update the `next` and `loop` targets to use `$(ORCH_FLAGS)`**

Find:
```makefile
next:
	AGENT_PROVIDER=$(AGENT) python3 -m tools.orchestrator --iterations 1 --tournament-size $(K)

loop:
	AGENT_PROVIDER=$(AGENT) python3 -m tools.orchestrator --iterations $(N) --tournament-size $(K)
```

Replace with:
```makefile
next:
	AGENT_PROVIDER=$(AGENT) python3 -m tools.orchestrator $(subst --iterations $(N),--iterations 1,$(ORCH_FLAGS))

loop:
	AGENT_PROVIDER=$(AGENT) python3 -m tools.orchestrator $(ORCH_FLAGS)
```

(`make next` always runs 1 iteration; `make loop` uses N. The `$(subst ...)` lets `next` reuse the same composed-flags machinery without forking it.)

- [ ] **Step 3: Update `make help` so the new flags show up**

Find:
```makefile
	@echo "  make next       — one orchestrator round (hypothesize -> implement -> eval)"
	@echo "                    flags: K=<slots> AGENT=codex|claude"
	@echo "  make loop N=10  — N orchestrator rounds"
	@echo "                    flags: K=<slots> AGENT=codex|claude"
```

Replace with:
```makefile
	@echo "  make next       — one orchestrator round (hypothesize -> implement -> eval)"
	@echo "                    flags: K=<slots> AGENT=codex|claude"
	@echo "                           BRANCH=<name> BASELINE=<gitref>"
	@echo "                           COREMARK=<iter/s> LUT=<count>"
	@echo "  make loop N=10  — N orchestrator rounds (same flags as `next`)"
```

- [ ] **Step 4: Verify with `make -n` for several flag combinations**

Run:
```bash
make -n loop N=10 K=3 | tail -1
make -n loop N=10 K=3 BRANCH=test_123 BASELINE=baseline COREMARK=300 LUT=3000 | tail -1
make -n next BRANCH=test_123 COREMARK=370 | tail -1
```
Expected output respectively:
```
AGENT_PROVIDER=codex python3 -m tools.orchestrator --iterations 10 --tournament-size 3
AGENT_PROVIDER=codex python3 -m tools.orchestrator --iterations 10 --tournament-size 3 --branch test_123 --baseline baseline --coremark-target 300 --lut-target 3000
AGENT_PROVIDER=codex python3 -m tools.orchestrator --iterations 1 --tournament-size 1 --branch test_123 --coremark-target 370
```

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -m "make: BRANCH/BASELINE/COREMARK/LUT pass-through + help text"
```

---

## Task 8: End-to-end smoke test

**Files:** none modified — verification only.

This task confirms the whole pipeline lights up with a minimal real run. It uses `--from-hypothesis` to pin a known-good YAML so we don't depend on the LLM agent for this smoke test.

- [ ] **Step 1: Create a minimal pre-written hypothesis (no-op baseline retest)**

Run:
```bash
mkdir -p experiments/hypotheses
cat > /tmp/hyp-smoke.yaml <<'EOF'
id: hyp-smoke-001-r1s0
title: Smoke test for research-mode loop (no-op)
category: micro_opt
motivation: |
  Confirms the BRANCH+BASELINE+targets flag plumbing produces the right
  branch, log path, and plot path. No RTL change.
hypothesis: |
  Set a sentinel to exercise the per-branch path machinery.
expected_impact:
  fitness_delta_pct: 0
  confidence: high
changes:
  - file: rtl/core.sv
    description: |
      Sentinel — no real change. skip_implementation:true bypasses the
      implementation agent.
skip_implementation: true
EOF
cp /tmp/hyp-smoke.yaml experiments/hypotheses/hyp-smoke-001-r1s0.yaml
```

- [ ] **Step 2: Confirm the `baseline` tag exists**

Run: `git tag -l baseline | wc -l`
Expected: `1` (so we can fork from it).

- [ ] **Step 3: Run a one-round smoke loop on a sandbox branch**

Run:
```bash
make loop N=1 K=1 \
        BRANCH=smoke-research \
        BASELINE=baseline \
        COREMARK=370 \
        LUT=8000 \
        AGENT=codex \
        --from-hypothesis=/tmp/hyp-smoke.yaml 2>&1 | tail -20
```

Note: `--from-hypothesis` is an orchestrator flag, not a make var. If `make` swallows it, instead invoke directly:
```bash
AGENT_PROVIDER=codex python3 -m tools.orchestrator \
        --iterations 1 --tournament-size 1 \
        --branch smoke-research \
        --baseline baseline \
        --coremark-target 370 --lut-target 8000 \
        --from-hypothesis /tmp/hyp-smoke.yaml 2>&1 | tail -20
```

Expected (rough):
- "fresh branch 'smoke-research' — running baseline retest"
- Baseline retest log entry written to `experiments/log-smoke-research.jsonl`.
- Round 1 runs the no-op hypothesis as slot 0; lands as either improvement (within Pareto rules) or regression.
- `experiments/progress-smoke-research.png` exists.

- [ ] **Step 4: Verify per-branch artifacts**

Run:
```bash
ls -la experiments/log-smoke-research.jsonl experiments/progress-smoke-research.png
git log --oneline smoke-research | head -5
git log --oneline main | head -2
```

Expected:
- Both per-branch files exist and are non-empty.
- `smoke-research` branch has at least one extra commit beyond main (the baseline retest log + plot).
- Main is unchanged.

- [ ] **Step 5: Verify the `existing-branch + BASELINE` hard-error path**

Run:
```bash
python3 -m tools.orchestrator \
        --iterations 1 --tournament-size 1 \
        --branch smoke-research \
        --baseline baseline 2>&1 | tail -3
```

Expected: `Branch 'smoke-research' already exists. To start fresh from 'baseline', run \`git branch -D smoke-research\` first.`

- [ ] **Step 6: Cleanup**

Run:
```bash
git checkout main
git branch -D smoke-research
rm -f experiments/log-smoke-research.jsonl experiments/progress-smoke-research.png \
      experiments/hypotheses/hyp-smoke-001-r1s0.yaml
```

- [ ] **Step 7: Final commit (no-op or doc/changelog if anything updated)**

If only verification was done with no file changes, no commit needed. Otherwise:
```bash
git status
# If clean, you're done.
```

---

## Self-review notes

After writing the plan, I checked it against the spec:

- **Spec coverage:** Every API row in the spec table maps to a task — Tasks 1, 5, 6 cover the accept rule and target wiring; Tasks 3, 6 cover branch routing and baseline retest; Tasks 4, 6 cover the prompt injection; Tasks 2, 6 cover per-branch log/plot paths; Task 7 covers the make-side flags.
- **Placeholders:** scanned for "TBD" / "implement later" / "handle edge cases" — none.
- **Type consistency:** the accept-rule signature `accept(old, new, coremark_target, lut_target)` is consistent across Task 1 (definition), Task 5 (caller), and Task 6 (downstream targets dict). The targets dict shape `{"coremark": int, "lut": int}` is consistent across orchestrator/tournament/hypothesis. The `current_lut` helper signature matches its callers. `target_branch` parameter naming matches across worktree.py (`target_branch`) and tournament.py (`target_branch`).
- **Worked-example sanity:** Task 1's tests match the spec's worked-example tables for both phase 1 and phase 2.
