# Research-mode loop: branches, dual-target Pareto, and baseline forks

**Status:** design — not yet implemented.
**Author:** felipe + claude.
**Date:** 2026-04-28.

## Goal

Extend `make loop` so a single command can run a research experiment that:

1. **Targets multiple objectives** (e.g., `COREMARK=300, LUT=3000`) instead of just maximizing CoreMark iter/s.
2. **Merges into a sandbox branch** (e.g., `BRANCH=efficiency`) instead of `main`, so experimental directions don't pollute the production champion.
3. **Forks RTL from any historical commit** (e.g., `BASELINE=baseline` or `BASELINE=v0-tag`), so a research run can start from V0 even after main has accepted dozens of hypotheses.
4. **Self-injects optimization context** into the hypothesis-agent prompt — the agent sees the targets and current state automatically; no human-authored prompt blob.

The default invocation `make loop N=10 K=3` is unchanged: maximize CoreMark on `main`, write to `experiments/log.jsonl`, plot to `experiments/progress.png`.

## API

```
make loop N=<rounds> K=<slots> AGENT=<codex|claude> \
        BRANCH=<branch>          # optional; merge target. Default: main.
        BASELINE=<gitref>        # optional; RTL fork point at branch creation. Default: main.
        COREMARK=<iter/s>        # optional; target on CoreMark axis. Default: unset.
        LUT=<count>              # optional; target on LUT4 axis. Default: unset.
```

Combinations and their effect:

| Invocation | Effect |
|---|---|
| `make loop N=10 K=3` | today's behavior — main, max-coremark, single fitness axis |
| `make loop N=10 K=3 COREMARK=370` | main, single-axis soft aspiration: deficit-driven below 370, max-coremark past 370 |
| `make loop N=10 K=3 BRANCH=foo` | sandbox branch off main, max-coremark |
| `make loop N=10 K=3 BRANCH=foo BASELINE=baseline` | sandbox branch starting from V0 RTL (the `baseline` tag), max-coremark |
| `make loop N=10 K=3 BRANCH=foo COREMARK=300 LUT=3000` | dual-target Pareto on a sandbox branch off main |
| `make loop N=70 K=3 BRANCH=test_123 BASELINE=baseline COREMARK=300 LUT=3000` | full thing — branch from V0, dual targets, Pareto/scalarizing accept |

### Removed flags

- ~~`GOAL=area|coremark`~~ — redundant. Targets imply direction (deficit_perf is positive when below, deficit_area is positive when below; the score function is direction-aware).
- ~~`PROMPT="..."`~~ — redundant. Targets and current state are injected into the hypothesis-agent prompt automatically.

## Accept rule

The accept rule depends on which targets are set.

### No targets (default)

`accept = candidate.fitness > champion.fitness` — exactly today's behavior.

### One target only (single-axis aspiration)

E.g. `COREMARK=370`. Use the deficit formula on the targeted axis only — same two-phase pattern as the dual-target case but with one axis instead of two:

```
score(perf) = min(0, (perf − COREMARK) / COREMARK)        # ≤ 0; saturates at 0 at/past target

def accept(old, new, COREMARK):
    s_old, s_new = score(old.perf), score(new.perf)
    if s_new > s_old:
        return True                          # phase 1: closing the deficit toward target
    if s_old == s_new == 0:
        return new.perf > old.perf           # phase 2: both past target → max-coremark
    return False
```

So below target the loop is pulled toward 370. Once past 370, it reverts to today's "any improvement is good" behaviour. A regression *back below* target is rejected (it would lower the score).

### Two targets (dual-target Pareto)

This is the main new mode. Define per-axis deficits that saturate at 0 once the axis reaches its target:

```
deficit_perf(perf) = min(0, (perf − COREMARK) / COREMARK)
deficit_area(lut)  = min(0, (LUT − lut) / LUT)
score(perf, lut)   = deficit_perf(perf) + deficit_area(lut)            # always ≤ 0
both_met(perf, lut) = perf ≥ COREMARK and lut ≤ LUT
```

Two-phase accept:

```
def accept(old, new, COREMARK, LUT):
    s_old = score(old.perf, old.lut)
    s_new = score(new.perf, new.lut)

    # Phase 1 — at least one axis still below target.
    if s_new > s_old:
        return True

    # Phase 2 — both axes already at/past target. Strict Pareto only.
    if s_new == s_old == 0 and both_met(old.perf, old.lut) and both_met(new.perf, new.lut):
        return ((new.perf >= old.perf and new.lut <= old.lut) and
                (new.perf >  old.perf or  new.lut <  old.lut))

    return False
```

#### Phase 1 examples (targets COREMARK=300, LUT=3000)

| Move | s_old | s_new | Verdict | Reason |
|------|-------|-------|---------|--------|
| (200, 5000) → (290, 5500) | −1.000 | −0.867 | accept | big perf-deficit recovery > area-deficit cost |
| (330, 3300) → (600, 4000) | −0.100 | −0.333 | reject | perf gain past target gives 0 credit; area got worse |
| (310, 3300) → (350, 3000) | −0.100 |   0.000 | accept | hit area target without losing perf |
| (310, 3300) → (290, 3000) | −0.100 | −0.033 | accept | hit area target; small perf loss within budget |

#### Phase 2 examples (current = (320, 2900); both met; score = 0)

| Hypothesis | Verdict | Reason |
|------------|---------|--------|
| (340, 2900) | accept | strict-dominates (perf↑, area=) |
| (320, 2700) | accept | strict-dominates (perf=, area↓) |
| (340, 2800) | accept | strict-dominates (perf↑, area↓) |
| (340, 2950) | reject | perf↑ paid for with area↑; past-target trades are off |
| (310, 2900) | reject | perf↓ for nothing |
| (350, 3050) | reject | regressed past area target → re-enters phase 1 with negative score |

The phase-2 elegance: a regression *past target* automatically resurrects the deficit, so the rule rejects it via the phase-1 score check — no special case.

## Branch + BASELINE semantics

Behaviour of the `BRANCH` × `BASELINE` cross-product:

| `BRANCH` | `BASELINE` | Branch exists? | Behaviour |
|----------|------------|----------------|-----------|
| unset | unset | n/a | today's behaviour: merge to `main`, write to `log.jsonl` |
| unset | set | n/a | **error**: "BASELINE requires BRANCH" |
| set | unset | no | create branch from `main`'s tip; first iteration runs a baseline retest |
| set | unset | yes | continue from the branch's tip; **no** baseline retest |
| set | set | no | create branch at `git rev-parse $BASELINE`; first iteration runs a baseline retest |
| set | set | yes | **error**: "Branch `<name>` already exists. To start fresh from `<ref>`, run `git branch -D <name>` first." |

Worktrees are always created from the **branch tip** (whichever branch the loop is operating on), so accepted hypotheses chain on the branch.

### First-iteration baseline retest

When a branch is freshly created (with or without an explicit BASELINE), the loop's first action before any hypothesis round:

1. Check out the new branch.
2. Run the eval gate (formal → cosim → fpga) on the branch tip's RTL.
3. Append the result as the first entry of `experiments/log-<branch>.jsonl`. The entry's id is `baseline-<branch>-<short-sha>`, outcome is `improvement`.
4. That entry's `(fitness, lut4)` becomes the comparison anchor for round 1.

Cost: one full eval cycle (~5–15 min on the FPGA target) before the research starts. Worth it for clean accounting — no implicit "this branch's anchor is the global baseline" assumption.

If the baseline retest fails any gate (formal/cosim/fpga), the loop aborts before any hypothesis round runs. The branch is left created at the BASELINE ref (so the user can investigate without re-running BASELINE).

### Branch routing in `tools/worktree.py`

Currently `accept_worktree` does `git merge --ff-only <branch>` against the implicit "currently checked out branch" (`main` in practice). The change:

- The orchestrator passes the active branch name into `accept_worktree`.
- `worktree.py` does `git checkout <branch>` (idempotent if already on it) before the merge.
- `create_worktree` is parameterised on the base branch — defaults to `main`, can be overridden.

### Per-branch artefacts

| Path | Default branch | Sandbox branch |
|------|----------------|----------------|
| Log | `experiments/log.jsonl` | `experiments/log-<branch>.jsonl` |
| Plot | `experiments/progress.png` | `experiments/progress-<branch>.png` |
| Hypothesis YAMLs (gitignored) | `experiments/hypotheses/hyp-…yaml` | unchanged |

Plot rendering for dual-target runs is a follow-up — see "Out of scope" below.

## Hypothesis-agent prompt injection

`tools/agents/hypothesis.py` builds the prompt today; it includes "Current best fitness: <number>" and the architecture summary. Add an "Optimization targets" section, generated from the active run's config:

```
## Optimization targets

This research run targets:
  CoreMark = {COREMARK} iter/s
  LUT4     = {LUT}

Current state:
  CoreMark   = {current.perf} iter/s   (deficit_perf = {dp:.3f}, {target_status_perf})
  LUT4       = {current.lut}           (deficit_area = {da:.3f}, {target_status_area})
  combined score = {dp+da:.3f}

Accept rule: deficit-driven in phase 1 (any axis below target);
strict Pareto-dominance in phase 2 (both at target).

Your hypothesis should attack whichever axis is currently failing.
If both targets are met, find a "free win" that strictly dominates
the current design on at least one axis without regressing the other.
```

If only one target is set, the prompt only mentions that axis. If neither, the new section is omitted entirely (back to today's prompt).

The implementation agent's prompt is **not** touched — it just executes whatever the YAML says.

## Files touched

| File | Purpose |
|------|---------|
| `Makefile` | `BRANCH`/`BASELINE`/`COREMARK`/`LUT` flag pass-through. |
| `tools/orchestrator.py` | New CLI args (`--branch`, `--baseline`, `--coremark-target`, `--lut-target`); branch+baseline lifecycle; per-branch log path. |
| `tools/tournament.py` | New accept rule; pick_winner becomes target-aware. |
| `tools/worktree.py` | Worktree-from-branch + merge-into-branch parameterisation. |
| `tools/agents/hypothesis.py` | Targets + current-state prompt injection. |
| `tools/plot.py` | Per-branch output paths. (Dual-target visualization is follow-up.) |
| `tools/eval/*` | Untouched — eval is pure (RTL → fitness numbers). |
| `schemas/eval_result.schema.json` | No change — already records `fitness` and `lut4`. |

The eval gate, formal contract, cosim methodology, and CoreMark CRC validation are entirely unchanged. The new behaviour is purely in the orchestrator's bookkeeping and accept logic.

## Backwards compatibility

`make loop N=10 K=3` invocation without any new flags is byte-identical to today's behaviour:

- Branch: `main`.
- Log: `experiments/log.jsonl`.
- Plot: `experiments/progress.png`.
- Accept rule: maximize fitness.
- Prompt: no "Optimization targets" section.

A run that previously appended to `log.jsonl` continues to do so. The `baseline` tag and existing log entries are not mutated.

## Edge cases and error handling

- `BASELINE` cannot be resolved by `git rev-parse` → error before any work starts.
- `BRANCH` is a name that conflicts with a tag → error (force the user to disambiguate).
- `COREMARK` or `LUT` parses as non-positive integer → error.
- First-iteration baseline retest fails a gate → abort the run; leave the branch created at BASELINE for inspection.
- Concurrent `make loop` runs targeting the same branch → undefined behavior (out of scope; the orchestrator already isn't designed for that).

## Out of scope (follow-ups)

- **Plot revision for dual-target mode.** A 2D scatter (LUT4 on x, CoreMark on y) with a target marker, accepted-trajectory line, and band of dominated rejected dots reads better than the current 1D line for Pareto runs. Plot.py stays 1D for now; we can iterate after the core feature lands.
- **More than two axes.** FF count, Fmax target, BRAM budget, etc. The accept rule generalizes (sum of N saturating deficits + N-dim strict Pareto in phase 2), but the API gets noisy. Defer until a real third-axis use case shows up.
- **Soft Pareto past target** (continuous deficit weight at, say, 10×). Adds a tunable; defer unless the strict-Pareto phase-2 rule turns out to stagnate in practice.
- **Auto-tuning of targets** (e.g., "set LUT to 80% of current") — out of scope; users supply concrete numbers.

## Acceptance / done definition

- All entries in the API table above produce the documented behaviour.
- Both phase-1 and phase-2 example tables produce the documented accept verdicts in `tests/`.
- A run with `BRANCH=foo BASELINE=baseline` creates `foo` from the `baseline` tag, runs a baseline retest, then proceeds with hypothesis rounds, all logging to `experiments/log-foo.jsonl`.
- `make loop N=10 K=3` (no new flags) produces a byte-identical-shape commit history to a pre-feature run.
