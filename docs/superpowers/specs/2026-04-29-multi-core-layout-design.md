# Multi-core layout for auto-arch-tournament

**Date:** 2026-04-29
**Status:** Design approved (pending spec review)
**Type:** Refactor — repository layout + harness/orchestrator path-awareness

## Summary

Today the repo holds exactly one core under `rtl/`. To experiment with multiple
core architectures (e.g., a baseline 5-stage in-order vs a Vex-style superscalar
vs a SERV-style tiny core) the user has been overloading git branches as
"core identity" — `experiments/log-<branch>.jsonl` is the existing per-branch
artifact precedent. That works for tracking results but breaks down because all
branches still share `rtl/`: switching branches loses your other core's design.

This refactor moves core identity to the **filesystem**: each core lives in
`cores/<name>/` with its own RTL, cocotb tests, philosophy doc, spec/metadata,
and experiment log. The orchestrator and harness learn to read a `TARGET=`
argument that selects which core to operate on.

Workflow stays branch-based: each new core lives on its own git branch
(`core-foo`), and is PR'd to `main` manually for review. Parallel core
development uses standard `git worktree add` to check out N branches in N
working directories.

## Goals

1. Develop and evaluate multiple core architectures in one repo, in parallel.
2. Each core's experiment artifacts (log, plot, hypotheses, philosophy, spec)
   live with the core's RTL — no global state-sharing between cores.
3. Per-core PR review: a new core appears on a branch as one self-contained
   `cores/<name>/` directory, easy to review and merge.
4. The eval contract (formal wrapper, FPGA bench, cosim main) remains shared
   across all cores — every core targets the same RVFI port shape, the same
   memory map, the same CoreMark validation.

## Non-goals

- Cross-core fitness comparison or a "tournament between cores" leaderboard.
  That's a future feature; this refactor only enables side-by-side existence.
- Different ISAs per core that the harness understands. `core.yaml` declares
  ISA but the harness doesn't (yet) gate behavior on it.
- Different target FPGAs per core that the harness understands. `core.yaml`
  declares `target_fpga` but `synth.tcl` / nextpnr config is not (yet) per-core.
- Replacing today's per-iteration evaluation worktrees (those stay; they just
  move from `experiments/worktrees/` to `cores/<TARGET>/worktrees/`).

## Repo layout

```
auto-arch-tournament/
├── cores/
│   ├── baseline/                       # seed: simple RTL from `baseline` git tag
│   │   ├── rtl/*.sv
│   │   ├── test/test_*.py
│   │   ├── core.yaml
│   │   ├── CORE_PHILOSOPHY.md          # may be empty
│   │   ├── experiments/
│   │   │   ├── log.jsonl
│   │   │   ├── progress.png
│   │   │   └── hypotheses/
│   │   ├── implementation_notes.md     # gitignored
│   │   ├── worktrees/                  # gitignored
│   │   ├── generated/                  # gitignored
│   │   └── obj_dir/                    # gitignored
│   └── v1/                             # seed: current evolved RTL on main HEAD
│       └── ...                          # same structure
├── tools/                              # shared (orchestrator, agents, eval)
├── formal/                             # shared (wrapper.sv = correctness contract)
├── fpga/                               # shared (core_bench.sv, scripts/)
├── test/
│   ├── cosim/                          # shared cosim harness
│   ├── test_accept_rule.py             # shared infra tests
│   └── test_tournament.py
├── bench/programs/                     # shared
├── schemas/                            # shared
└── Makefile, README.md, CLAUDE.md, ARCHITECTURE.md, setup.sh
```

### What lives per-core

- `rtl/*.sv` — the design.
- `test/test_*.py` — cocotb unit tests for this core's modules. The agent is
  allowed to add/edit these (within ALLOWED_PATTERNS).
- `core.yaml` — declared spec + auto-updated current measurements (see schema).
- `CORE_PHILOSOPHY.md` — optional; injected into agent prompts when present.
- `experiments/log.jsonl` — accept-log (replaces today's
  `experiments/log-<branch>.jsonl`).
- `experiments/progress.png` — plot of fitness over time.
- `experiments/hypotheses/*.yaml` — agent-generated hypothesis files.
- `implementation_notes.md` — gitignored, per-iteration agent writeup.
- `worktrees/` — gitignored, per-hypothesis evaluation worktrees.
- `generated/` — gitignored, yosys synth output.
- `obj_dir/` — gitignored, verilator cosim build.

### What stays shared

- `tools/` — orchestrator, agents, eval gates, plot, tournament, accept_rule.
- `formal/wrapper.sv`, `formal/checks.cfg`, `formal/run_all.sh` — the RVFI
  correctness contract. Fixed across all cores per CLAUDE.md (NRET=2 contract).
- `fpga/core_bench.sv`, `fpga/scripts/synth.tcl`, `fpga/constraints/` — the
  FPGA fitness contract.
- `test/cosim/main.cpp`, `test/cosim/build.sh`, `test/cosim/reference.py`,
  `test/cosim/run_cosim.py` — the cosim contract.
- `bench/programs/` — selftest, coremark, crt0, link.ld, portme.
- `schemas/`, `setup.sh`, `Makefile`, `README.md`, `CLAUDE.md`,
  `ARCHITECTURE.md`.

## `core.yaml` schema

`core.yaml` is metadata-only. The harness does not consume it for behavior
(Phase A); it's surfaced in agent prompts and `make report`. Two sections:

```yaml
# cores/<name>/core.yaml
name: nicebrev
description: Two-issue in-order with 4KB I-cache
isa: rv32im                # declared, fixed
target_fpga: ice40hx8k     # declared, drives no harness behavior in Phase A

targets:                   # declared aspirations — manually edited
  fmax_mhz: 90
  lut4: 3000
  coremark_iter_s: 400
  coremark_per_mhz: 4.5

current:                   # auto-updated by orchestrator after each accepted improvement
  fmax_mhz: 78.4
  lut4: 2647
  ff: 1834
  coremark_iter_s: 312.6
  coremark_per_mhz: 3.99
  source_id: hyp-20260429-043-r22s0
  updated: 2026-04-29T11:31:00Z
```

The orchestrator writes `current:` in the same `accept_worktree` transaction
that lands the implementation merge and the log+plot commit.

## CORE_PHILOSOPHY.md

Optional file at `cores/<TARGET>/CORE_PHILOSOPHY.md`. When present and non-empty,
the orchestrator injects its contents into both the hypothesis-agent prompt and
the implementation-agent prompt under a labeled section (e.g.,
`## Core philosophy / architect's hard constraints`). Used to encode design
intent that's not derivable from RTL alone (e.g., "minimize LUT4 above all else;
reject any hypothesis that exceeds 2500 LUT4 even if fitness improves").

**Prompt timing.** The user is prompted to author this file only at fork
creation time (when `cores/<TARGET>/` is being newly created from a base). At
that moment the orchestrator prints to stderr:

```
Optional: write the philosophy for cores/foo (constraints, style, intent).
Press Ctrl-D / empty + Enter to skip.
```

and reads stdin until EOF. Whatever the user types is written to
`cores/foo/CORE_PHILOSOPHY.md` (a 0-byte file if they just hit Enter). The
orchestrator never re-prompts on subsequent runs; the user edits the file by
hand to change it.

**Headless safety.** If `sys.stdin.isatty()` is false (orchestrator launched
from cron, a pipe, or a CI runner) the prompt is skipped and an empty
philosophy file is created silently. This avoids hanging an automated loop.

## Orchestrator semantics

The orchestrator no longer manages git branches or git refs. It only sees
filesystem state. The user manages branches manually (Model A workflow): one
branch per new core, PR'd to main when done. For parallel cores, the user
creates additional working directories with `git worktree add <path> <branch>`.

The `--branch` and `--baseline` flags in today's orchestrator go away entirely.
New flags: `--target` (required) and `--base` (optional).

### `make loop TARGET=foo BASE=bar`

- `cores/foo/` absent → fork from `cores/bar/`. Specifically:
  1. Copy `cores/bar/rtl/`, `cores/bar/test/`, and `cores/bar/core.yaml` into
     `cores/foo/`. Do **not** copy `CORE_PHILOSOPHY.md` — philosophy is
     per-core intent and shouldn't bleed across forks. Do **not** copy
     `experiments/` — the new core gets its own log.
  2. Prompt user for `cores/foo/CORE_PHILOSOPHY.md` (TTY-gated; see above).
     Always asked, regardless of whether the source had one.
  3. Reset `cores/foo/core.yaml`'s `current:` section to empty (the targets
     section carries forward from the source, since the user usually wants
     to inherit the same aspirations on a fork).
  4. Run a one-shot baseline retest against `cores/foo/rtl/` to populate the
     first log entry and `current:` (today's `_run_baseline_retest` flow).
  5. Commit the fork: `feat: fork cores/foo from cores/bar`.
  6. Begin tournament rounds.
- `cores/foo/` exists → **error** with message:
  > `cores/foo/ already exists. Drop BASE= to continue iterating, or `git rm -r cores/foo` to start over.`

### `make loop TARGET=foo` (no BASE)

- `cores/foo/` absent → defaults `BASE=baseline`, runs the fork flow above.
- `cores/foo/` exists → **continue iterating** from current state. This is the
  restart-a-loop / resume-a-loop semantics. No prompt, no baseline retest.

### `make loop` (no TARGET)

- Error, list cores discovered under `cores/`:
  > `TARGET= required. Available cores: baseline, v1, nicebrev`

### Per-iteration behavior

Per-iteration semantics (hypothesize → implement → eval → accept) are unchanged
in spirit. Only the paths the orchestrator and agents touch change:

- Worktree creation: `cores/<TARGET>/worktrees/<id>/`.
- ALLOWED_PATTERNS (sandbox enforcement) becomes:
  - `^cores/<TARGET>/rtl/.+`
  - `^cores/<TARGET>/test/test_[^/]+\.py$`
  - `^cores/<TARGET>/implementation_notes\.md$`
  - `^cores/<TARGET>/core\.yaml$` (so the orchestrator can update `current:`)
- Log + plot writes: `cores/<TARGET>/experiments/log.jsonl` +
  `cores/<TARGET>/experiments/progress.png`.

## Harness changes

| File | Change |
|---|---|
| `tools/orchestrator.py` | Add `--target` (required) and `--base` (optional). Drop `--branch` and `--baseline`. ALLOWED_PATTERNS becomes a function of TARGET. LOG_PATH/PLOT_PATH become per-TARGET. |
| `tools/worktree.py` | `git add -A cores/<TARGET>/` instead of `rtl/`. Worktree path becomes `cores/<TARGET>/worktrees/<id>`. |
| `tools/agents/hypothesis.py` | Prompt references `cores/<TARGET>/rtl/`. CORE_PHILOSOPHY.md content injected when non-empty. `core.yaml` content injected so the agent sees declared targets. |
| `tools/agents/implement.py` | Prompt references `cores/<TARGET>/rtl/`. Lint command becomes `verilator --lint-only -Wall -Wno-MULTITOP -sv cores/<TARGET>/rtl/*.sv`. CORE_PHILOSOPHY.md content injected when non-empty. |
| `tools/eval/formal.py` | Takes `target` parameter. Resolves `rtl_dir = f"cores/{target}/rtl"`. Passes via env to `formal/run_all.sh`. |
| `tools/eval/cosim.py` | Takes `target` parameter. Resolves `rtl_dir` and `obj_dir` per-target. |
| `tools/eval/fpga.py` | Takes `target` parameter. Resolves `rtl_dir` and `generated/` per-target. Writes `current:` section of `cores/<target>/core.yaml` after a successful eval. |
| `tools/plot.py` | Takes log path and out path as parameters (already does); orchestrator passes per-TARGET paths. |
| `formal/run_all.sh` | Takes `RTL_DIR` env var (defaults to `rtl` for backward-compat during migration). Stages `$RTL_DIR/*.sv` instead of hardcoded `rtl/*.sv`. |
| `fpga/scripts/synth.tcl` | Reads `RTL_DIR` from environment (`set rtl_dir [lindex $::env(RTL_DIR) 0]` with fallback to `rtl`). Globs `$rtl_dir/*.sv`. |
| `test/cosim/build.sh` | Takes `RTL_DIR` and `OBJ_DIR` as positional args (or env vars) so two cores can build in parallel without colliding. |
| `Makefile` | Every core-touching target (`lint`, `test`, `cosim`, `formal`, `fpga`, `next`, `loop`, `report`) takes `TARGET=<name>`. Empty TARGET on those targets prints an error and the list of available cores. The `bench` and `clean` targets stay non-targeted. |

## Migration

One-shot script (or hand-run sequence). The migration commit is the only
"big bang" — everything after this is incremental per-core PRs.

1. **Seed `cores/baseline/`** from the `baseline` git tag:
   ```bash
   mkdir -p cores/baseline
   git read-tree --prefix=cores/baseline/rtl/ baseline:rtl
   git checkout-index -a --prefix=cores/baseline/rtl/
   # (or simpler: git archive baseline rtl/ | tar -xC cores/baseline/ --strip-components=0)
   ```
   Create `cores/baseline/core.yaml` with declared targets but empty
   `current:` (the first orchestrator run will populate it). Create empty
   `cores/baseline/CORE_PHILOSOPHY.md`. Create empty `cores/baseline/test/`.

2. **Seed `cores/v1/`** from the current `rtl/` on main HEAD:
   ```bash
   git mv rtl cores/v1/rtl
   mkdir cores/v1/test
   # move per-core cocotb tests
   git mv test/test_alu.py cores/v1/test/  # etc.
   # (test_accept_rule.py and test_tournament.py stay at top-level)
   ```
   Create `cores/v1/core.yaml` with declared targets and `current:` populated
   from the most recent improvement entry in `experiments/log.jsonl`. Create
   empty `cores/v1/CORE_PHILOSOPHY.md` (or carry forward from CLAUDE.md
   intent).

3. **Move existing experiment artifacts:**
   ```bash
   mkdir -p cores/v1/experiments
   git mv experiments/log.jsonl cores/v1/experiments/log.jsonl
   git mv experiments/progress.png cores/v1/experiments/progress.png
   git mv experiments/hypotheses cores/v1/experiments/hypotheses
   ```
   The existing per-branch logs (`experiments/log-beat_vex.jsonl`,
   `experiments/log-hyp-*.jsonl`) are left in place as historical artifacts. If
   the user wants any of them resurrected as a forked core, they can manually
   `git mv` to the appropriate `cores/<name>/experiments/log.jsonl` later.

4. **Delete vex stubs:**
   ```bash
   git rm test/cosim/build_vex.sh test/cosim/vex_main.cpp
   ```

5. **Update `.gitignore`:** add
   ```
   cores/*/worktrees/
   cores/*/generated/
   cores/*/obj_dir/
   cores/*/implementation_notes.md
   ```
   Remove the old `experiments/worktrees/` line if present.

6. **Update `CLAUDE.md`:**
   - "Don't-touch list" updated to reference shared paths only.
   - "What hypotheses MAY change" updated to `cores/<TARGET>/rtl/` and
     `cores/<TARGET>/test/test_*.py`.

7. **Update `Makefile`:** add `TARGET=` plumbing per the harness changes table.

8. **Update orchestrator + agents + eval modules** per the harness changes
   table.

9. **Verify with both cores:**
   ```bash
   make lint TARGET=baseline   # should pass on the simple seed
   make lint TARGET=v1         # should pass on the current evolved core
   make formal TARGET=baseline # baseline passes formal (it's the original)
   make cosim TARGET=v1        # v1's cosim still passes
   make fpga TARGET=v1         # v1's fpga eval still produces the current fitness
   ```
   Then a smoke loop: `make loop TARGET=v1 N=1` to confirm the orchestrator
   round-trip works end-to-end on a single iteration.

## Open questions / future work

- **Cross-core comparison.** Not in scope for this refactor. Could later add a
  `make leaderboard` that reads each `cores/*/core.yaml`'s `current:` section.
- **`core.yaml` as authoritative spec (Phase B).** Future work: have
  `synth.tcl` and `nextpnr` actually consume `target_fpga`, and have the
  orchestrator's accept rule consume `targets:`. Phase A defers all of this to
  the user / CLI flags.
- **Per-core formal contract.** All cores share `formal/wrapper.sv` and the
  NRET=2 RVFI port shape. If a future core needs a different formal contract,
  this assumption breaks and the wrapper would need a per-core variant. Not
  anticipated for any near-term core.
- **Vex re-introduction.** Once the layout lands and a real `cores/vex/` is
  created (forking from baseline or built from scratch), the deleted
  `vex_main.cpp` may be reintroduced — but as `cores/vex/cosim_main.cpp` if a
  per-core cosim main is ever needed. Today the shared `test/cosim/main.cpp`
  is sufficient.

## Risks

- **`fpga/scripts/synth.tcl` env-var read.** Yosys's TCL doesn't have a clean
  `getenv` with default. Need to guard with `[info exists ::env(RTL_DIR)]` and
  fall back to `rtl` (preserving backward compatibility during migration). If
  this is fragile, the alternative is to have the Makefile pass `-D RTL_DIR=...`
  on the yosys command line and parse it from `argv` in TCL.
- **`test/cosim/build.sh` parallel safety.** Two cores building cosim in
  parallel must use distinct `obj_dir`. If we miss a hardcoded path, two
  parallel builds will silently corrupt each other. Mitigation: search for any
  remaining `obj_dir` literal in the cosim sources after the refactor.
- **Migration commit size.** Moving every file under `rtl/` and `test/` is a
  big diff. Consider doing the migration in a dedicated PR with no other
  changes, so review focuses on "did anything get lost."
