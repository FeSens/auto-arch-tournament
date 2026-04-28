# Speculative Tournament Loop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the sequential `run_iteration` in `tools/orchestrator.py` with a `run_tournament_round` that generates and implements N hypotheses in parallel, serializes the heavy eval phases, and accepts only the round's highest-fitness winner.

**Architecture:** N slots execute Phase 1 (hypothesis-gen) and Phase 2 (implement) concurrently — both are network-bound on the Anthropic API. Phases 3–6 (lint/synth/build, formal, cosim, FPGA) run through a per-phase `Semaphore` so the CPU-bound steps (formal=1, fpga=1) are serialized while lint/build/cosim can overlap. After every slot finishes, a winner-pick step accepts the highest-fitness slot that beat the start-of-round best (`accept_worktree`); every other slot is destroyed (`destroy_worktree`). One log entry per slot is appended through a `threading.Lock` so the auto-commit doesn't race. `N=1` falls through the same code path and reproduces today's sequential behavior exactly.

**Tech Stack:** Python 3.11+ stdlib (`concurrent.futures.ThreadPoolExecutor`, `threading.Lock`, `threading.Semaphore`); existing `jsonschema`, `pyyaml`, `matplotlib` deps. No new third-party packages.

---

## Pre-flight notes (read before starting)

- **LUT4 / CRC numbers in the spec brief are stale.** The brief mentions `5396 LUT4` and CRCs `0xd4b0/0xbe52/0x5e47`. The authoritative numbers (in `experiments/log.jsonl` row 1 and `tools/eval/fpga.py:COREMARK_EXPECTED`) are **`9563 LUT4`** and CRCs **`0xe714 / 0x1fd7 / 0x8e3a / 0xfcaf`** (`seedcrc=0xe9f5`). The N=1 regression target is `fitness=282.82, fmax=127.03, lut4=9563, ff=1866, seeds=[128.72, 127.03, 123.02]` — match these, not the brief's typo'd numbers.
- **Don't weaken any invariant** in `CLAUDE.md`. The orchestrator-level sandbox check (`offlimits_changes` in `orchestrator.py`) and the agent-level check (`_git_offlimits_changes` in `hypothesis.py`) are part of the trust contract — only their plumbing changes here, not their effect.
- **`formal/riscv-formal/`** is a gitignored vendored repo. If missing, run `git clone https://github.com/YosysHQ/riscv-formal formal/riscv-formal` (or `bash setup.sh`) before any test that runs `make formal`.
- **Concurrency safety boundary:** Anthropic's API and `claude -p` are safe to invoke in parallel. The risky shared resources are: (a) `experiments/hypotheses/` filename collisions (handled by pre-allocated IDs); (b) `git status --porcelain` in main during sandbox check (handled by per-round whitelist); (c) `experiments/log.jsonl` + git auto-commit (handled by `Lock`); (d) Yosys/nextpnr CPU saturation (handled by phase semaphore).

## File structure

Files modified or created in this plan:

- `tools/orchestrator.py` (modify) — replace `run_iteration` with `run_tournament_round`; add `--tournament-size` CLI flag; serialize `append_log` via a module-level `Lock`.
- `tools/tournament.py` (NEW) — per-round orchestration: ID pre-allocator, diversity rotation, slot lifecycle, eval queue (semaphores), winner picker.
- `tools/agents/hypothesis.py` (modify) — accept pre-allocated `hyp_id`, accept per-round whitelist, accept `category` override; add single-retry on non-zero claude exit.
- `tools/agents/implement.py` (modify) — add single-retry on non-zero claude exit.
- `schemas/hypothesis.schema.json` (modify) — broaden `id` regex to permit optional `-rRsS` suffix.
- `tools/plot.py` (modify) — add round-banding (translucent vertical band per round) when entries carry `round_id`.
- `tools/test_tournament.py` (NEW) — unit tests for the pure helpers (ID allocator, category rotation, winner picker).
- `experiments/hypotheses/hyp-20260427-002.yaml` (regenerated locally, gitignored) — N=1 regression fixture.
- `experiments/hypotheses/hyp-20260427-003.yaml` (regenerated locally, gitignored) — deliberately-bad fixture for the broken-slot test.

---

## Task 1: Loosen hypothesis-ID schema regex

**Files:**
- Modify: `schemas/hypothesis.schema.json`

The current `id` pattern (`^hyp-[0-9]{8}-[0-9]{3}$`) rejects the new `hyp-YYYYMMDD-NNN-rRsS` shape. Loosen it so the suffix is optional (back-compat) and present-and-well-formed when used.

- [ ] **Step 1: Edit the regex**

Open `schemas/hypothesis.schema.json` and change line 7:

```json
"id":       {"type": "string", "pattern": "^hyp-[0-9]{8}-[0-9]{3}(-r[0-9]+s[0-9]+)?$"},
```

- [ ] **Step 2: Verify both forms validate, the malformed form rejects**

Run:

```bash
python3 -c "
import json, jsonschema
schema = json.load(open('schemas/hypothesis.schema.json'))
hyp = lambda i: {'id': i, 'title': 'x'*10, 'category': 'micro_opt',
                 'motivation': 'x'*30, 'hypothesis': 'x'*30,
                 'expected_impact': {'fitness_delta_pct': 0, 'confidence': 'high'},
                 'changes': [{'file': 'rtl/core.sv', 'description': 'noop'}]}
jsonschema.validate(hyp('hyp-20260427-001'), schema)            # legacy
jsonschema.validate(hyp('hyp-20260427-001-r1s0'), schema)       # new
try:
    jsonschema.validate(hyp('hyp-20260427-001-r1'), schema)     # malformed
    print('FAIL: malformed id accepted')
except jsonschema.ValidationError:
    print('OK')
"
```

Expected: prints `OK`.

- [ ] **Step 3: Commit**

```bash
git add schemas/hypothesis.schema.json
git commit -m "schemas: allow hyp-YYYYMMDD-NNN-rRsS tournament-id suffix"
```

---

## Task 2: New module `tools/tournament.py` — pure helpers (TDD)

**Files:**
- Create: `tools/tournament.py`
- Create: `tools/test_tournament.py`

Three pure helpers gated by tests so we have a fast feedback loop before touching the orchestrator: `allocate_round_ids`, `category_for_slot`, `pick_winner`.

- [ ] **Step 1: Write the failing tests**

Create `tools/test_tournament.py`:

```python
"""Unit tests for tools/tournament.py pure helpers (no claude / no FPGA)."""
import datetime
import pytest

from tools.tournament import (
    allocate_round_ids,
    category_for_slot,
    pick_winner,
)


def test_allocate_round_ids_basic():
    ids = allocate_round_ids(round_id=1, tournament_size=3,
                             today="20260427", first_seq=2)
    assert ids == [
        "hyp-20260427-002-r1s0",
        "hyp-20260427-003-r1s1",
        "hyp-20260427-004-r1s2",
    ]


def test_allocate_round_ids_n_equals_one():
    ids = allocate_round_ids(round_id=1, tournament_size=1,
                             today="20260427", first_seq=1)
    assert ids == ["hyp-20260427-001-r1s0"]


def test_category_for_slot_cycles_through_enum():
    assert category_for_slot(0) == "micro_opt"
    assert category_for_slot(1) == "structural"
    assert category_for_slot(2) == "predictor"
    assert category_for_slot(3) == "memory"
    assert category_for_slot(4) == "extension"
    # Slot 5 wraps:
    assert category_for_slot(5) == "micro_opt"


def _entry(slot, fitness, outcome="improvement"):
    return {"slot": slot, "fitness": fitness, "outcome": outcome}


def test_pick_winner_highest_fitness_above_baseline():
    entries = [_entry(0, 280.0), _entry(1, 290.0), _entry(2, 285.0)]
    winner = pick_winner(entries, current_best=282.82)
    assert winner["slot"] == 1


def test_pick_winner_no_slot_beats_baseline_returns_none():
    entries = [_entry(0, 280.0), _entry(1, 281.0), _entry(2, 282.0)]
    winner = pick_winner(entries, current_best=282.82)
    assert winner is None


def test_pick_winner_skips_broken_slots():
    entries = [
        {"slot": 0, "fitness": None, "outcome": "broken"},
        {"slot": 1, "fitness": 290.0, "outcome": "improvement"},
        {"slot": 2, "fitness": None, "outcome": "placement_failed"},
    ]
    winner = pick_winner(entries, current_best=282.82)
    assert winner["slot"] == 1


def test_pick_winner_all_broken_returns_none():
    entries = [
        {"slot": 0, "fitness": None, "outcome": "broken"},
        {"slot": 1, "fitness": None, "outcome": "broken"},
    ]
    winner = pick_winner(entries, current_best=282.82)
    assert winner is None
```

- [ ] **Step 2: Run the tests — they should fail (module missing)**

```bash
pytest tools/test_tournament.py -v
```

Expected: `ImportError: cannot import name 'allocate_round_ids' from 'tools.tournament'` (or "no module named tools.tournament").

- [ ] **Step 3: Implement the helpers**

Create `tools/tournament.py`:

```python
"""Speculative-tournament orchestration helpers.

The orchestrator delegates to this module for per-round logic so the pure
helpers (ID allocation, diversity rotation, winner picking) can be unit
tested without claude or the FPGA toolchain.
"""
from __future__ import annotations

import datetime
from typing import Optional

# The hypothesis schema's `category` enum, in the order the brief specifies.
# Slot index modulo len(CATEGORIES) picks one — slot 5+ wraps. This keeps
# round diversity deterministic while still letting the agent pick a
# different angle for each slot.
CATEGORIES: list[str] = [
    "micro_opt",
    "structural",
    "predictor",
    "memory",
    "extension",
]


def category_for_slot(slot: int) -> str:
    """Return the diversity category for a slot index, wrapping at 5."""
    return CATEGORIES[slot % len(CATEGORIES)]


def allocate_round_ids(
    round_id: int,
    tournament_size: int,
    today: Optional[str] = None,
    first_seq: int = 1,
) -> list[str]:
    """Pre-allocate `tournament_size` hypothesis IDs for a round.

    IDs follow `hyp-YYYYMMDD-NNN-rRsS` so they're unique across slots
    AND back-compat with the legacy `hyp-YYYYMMDD-NNN` shape (the
    schema regex now accepts both). Pre-allocation is the fix for the
    `_next_id` race: two slots calling it concurrently would otherwise
    pick the same NNN.
    """
    if today is None:
        today = datetime.date.today().strftime("%Y%m%d")
    return [
        f"hyp-{today}-{(first_seq + s):03d}-r{round_id}s{s}"
        for s in range(tournament_size)
    ]


def pick_winner(entries: list[dict], current_best: float) -> Optional[dict]:
    """Return the round's winner: highest-fitness slot that beat current_best.

    Slots without a fitness number (broken / placement_failed / cosim_failed)
    are ignored. Returns None if no slot cleared the bar — in that case the
    round produces no accept and the cumulative champion stays where it was.
    """
    candidates = [
        e for e in entries
        if isinstance(e.get("fitness"), (int, float))
        and e["fitness"] > current_best
    ]
    if not candidates:
        return None
    return max(candidates, key=lambda e: e["fitness"])
```

- [ ] **Step 4: Run tests — should pass**

```bash
pytest tools/test_tournament.py -v
```

Expected: `7 passed`.

- [ ] **Step 5: Commit**

```bash
git add tools/tournament.py tools/test_tournament.py
git commit -m "tournament: pure helpers — ID allocator, category rotation, winner picker"
```

---

## Task 3: Hypothesis agent — accept pre-allocated ID, whitelist, category

**Files:**
- Modify: `tools/agents/hypothesis.py`

The agent needs three new inputs from the orchestrator: an explicit `hyp_id` to use (replacing the racy `_next_id`), an explicit per-round `allowed_yaml_ids` whitelist (so concurrent slots don't trip each other), and a `category` to inject into the prompt for diversity. Keep `_next_id` for legacy callers (no callers remain after this round, but it's harmless and lets us land Task 3 before Task 4 without a wedge).

- [ ] **Step 1: Add the new signature, keep the old behavior as default**

Edit `tools/agents/hypothesis.py`. Replace the `run_hypothesis_agent` function signature and the `_git_offlimits_changes` invocation. The full new shape is below (replace from line 126 to end of file):

```python
def _whitelist_regex(allowed_yaml_ids: list[str]) -> 're.Pattern':
    """Build a regex matching ONLY the round's pre-allocated YAML names.

    Concurrent hypothesis agents share `experiments/hypotheses/` in the
    main repo. Without a per-round whitelist, slot 0's check would see
    slot 1's YAML as "off-limits" the moment slot 1 finished writing.
    The pre-allocated IDs are the deterministic, finite set of YAMLs the
    round is allowed to produce; anything else is a real breach.
    """
    if not allowed_yaml_ids:
        return HYP_ALLOWED  # back-compat: any YAML in experiments/hypotheses/
    alt = "|".join(re.escape(i) for i in allowed_yaml_ids)
    return re.compile(rf"^experiments/hypotheses/({alt})\.(yaml|yml)$")


def _git_offlimits_changes(allow_re: 're.Pattern' = HYP_ALLOWED) -> list:
    """git status --porcelain in the main repo; flag anything not matching
    the supplied allow regex. Default is the original any-YAML allow list."""
    out = subprocess.run(
        ["git", "status", "--porcelain"],
        capture_output=True, text=True, check=True,
    ).stdout
    bad = []
    for line in out.splitlines():
        if not line:
            continue
        for p in (s.strip() for s in line[3:].split(" -> ")):
            if p and not allow_re.match(p):
                bad.append(p)
    return bad


def run_hypothesis_agent(
    log_tail: list,
    current_fitness: float,
    baseline_fitness: float,
    hyp_id: str | None = None,
    allowed_yaml_ids: list[str] | None = None,
    category_hint: str | None = None,
) -> str:
    """Invokes claude -p and returns path to written hypothesis YAML.

    Sandbox: if the agent touches anything outside the round's whitelist
    (default: any YAML in experiments/hypotheses/), revert those changes
    and raise. The orchestrator catches this and logs a 'broken' iteration.

    Tournament-mode args:
      hyp_id           — pre-allocated ID. Skips _next_id (racy under N>1).
      allowed_yaml_ids — round's full pre-allocated ID list; tightens the
                         sandbox regex so concurrent slots don't flag each
                         other's legitimate YAMLs.
      category_hint    — injected into the prompt; the slot's category per
                         the diversity rotation (micro_opt / structural /
                         predictor / memory / extension).
    """
    if hyp_id is None:
        hyp_id = _next_id()
    prompt = _build_prompt(log_tail, current_fitness, baseline_fitness,
                           hyp_id=hyp_id, category_hint=category_hint)
    allow_re = _whitelist_regex(allowed_yaml_ids or [])
    # ...rest of the function body unchanged through `proc.wait()` ...
```

The full edit also needs to:
- Update `_build_prompt` to accept `hyp_id` and `category_hint` keyword args.
- Pass `allow_re` into `_git_offlimits_changes(allow_re)`.

Show the full revised `_build_prompt`:

```python
def _build_prompt(log_tail: list, current_fitness: float, baseline_fitness: float,
                  hyp_id: str | None = None,
                  category_hint: str | None = None) -> str:
    arch = Path("ARCHITECTURE.md").read_text()
    claude_md = Path("CLAUDE.md").read_text() if Path("CLAUDE.md").exists() else ""
    src_files = sorted(Path("rtl").rglob("*.sv"))
    src_dump  = "\n\n".join(
        f"=== {f} ===\n{f.read_text()}" for f in src_files
    )
    log_str = "\n".join(json.dumps(e) for e in log_tail)

    id_clause = (
        f"Use exactly this hypothesis ID: {hyp_id}\n"
        if hyp_id else
        "The hypothesis ID must follow the format: hyp-YYYYMMDD-NNN\n"
        "where NNN is a zero-padded sequence number based on existing files.\n"
    )
    category_clause = (
        f"Focus this hypothesis on the category: {category_hint}.\n"
        f"This is the diversity slot for this tournament round — pick the\n"
        f"single most promising '{category_hint}' angle, not a hedge across\n"
        f"categories.\n"
        if category_hint else ""
    )

    return f"""You are a CPU microarchitecture research agent.

Your job: propose one architectural hypothesis to improve this RV32IM CPU.
Fitness metric: CoreMark iter/sec = CoreMark iterations/cycle × Fmax_Hz on Tang Nano 20K FPGA.
Current best fitness: {current_fitness:.2f}
Baseline fitness: {baseline_fitness:.2f}

{category_clause}
## Architecture
{arch}

## Hard invariants (do NOT propose changes that weaken these)
{claude_md}

## Current SystemVerilog Source (rtl/)
{src_dump}

## Recent Experiment Log (last 20 entries)
{log_str if log_str else "(no experiments yet — this is the first iteration)"}

## Instructions
1. Analyze the source and experiment log carefully.
2. Identify the most promising architectural improvement.
3. Write a hypothesis YAML file to: experiments/hypotheses/<id>.yaml

{id_clause}
The YAML must validate against schemas/hypothesis.schema.json:
  id, title, category, motivation, hypothesis, expected_impact, changes

Each `changes[i].file` must be a path under rtl/ (this is an SV-source-
of-truth project; do NOT propose Chisel/Scala edits).

Write the file now using your Write tool. Do not output anything else."""
```

And the full revised tail of `run_hypothesis_agent` (replace the `breaches = _git_offlimits_changes()` block):

```python
    breaches = _git_offlimits_changes(allow_re)
    if breaches:
        for p in breaches:
            subprocess.run(["git", "checkout", "HEAD", "--", p],
                           capture_output=True)
            path = Path(p)
            if path.exists() and p not in [
                line.split()[-1] for line in subprocess.run(
                    ["git", "ls-files"],
                    capture_output=True, text=True).stdout.splitlines()
            ]:
                path.unlink(missing_ok=True)
        raise PermissionError(
            f"Hypothesis agent modified off-limits paths and was rolled back: {breaches}"
        )

    path = HYPOTHESES_DIR / f"{hyp_id}.yaml"
    if not path.exists():
        # Tournament mode: ID was pre-allocated; the agent may still have
        # written it under a slightly different name. Look for ANY YAML
        # matching this run's allowed set — newest wins.
        candidates = [HYPOTHESES_DIR / f"{i}.yaml" for i in (allowed_yaml_ids or [])]
        candidates = [c for c in candidates if c.exists()]
        if candidates:
            path = max(candidates, key=lambda f: f.stat().st_mtime)
        else:
            files = sorted(HYPOTHESES_DIR.glob("hyp-*.yaml"),
                           key=lambda f: f.stat().st_mtime)
            if files:
                path = files[-1]
            else:
                raise FileNotFoundError("Hypothesis agent did not write a hypothesis file.")
    return str(path)
```

- [ ] **Step 2: Sanity-check the import still works**

```bash
python3 -c "from tools.agents.hypothesis import run_hypothesis_agent, _whitelist_regex, allocate_round_ids" 2>&1 | head
```

Wait — `allocate_round_ids` lives in `tools.tournament`, not `hypothesis`. Adjust:

```bash
python3 -c "from tools.agents.hypothesis import run_hypothesis_agent, _whitelist_regex; from tools.tournament import allocate_round_ids; print('ok')"
```

Expected: `ok`.

- [ ] **Step 3: Quick whitelist regex test**

```bash
python3 -c "
from tools.agents.hypothesis import _whitelist_regex
ids = ['hyp-20260427-001-r1s0', 'hyp-20260427-002-r1s1']
r = _whitelist_regex(ids)
assert r.match('experiments/hypotheses/hyp-20260427-001-r1s0.yaml')
assert r.match('experiments/hypotheses/hyp-20260427-002-r1s1.yaml')
assert not r.match('experiments/hypotheses/hyp-20260427-003-r1s2.yaml')  # not in whitelist
assert not r.match('rtl/core.sv')
print('ok')
"
```

Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add tools/agents/hypothesis.py
git commit -m "hypothesis agent: pre-allocated ID, per-round whitelist, category injection"
```

---

## Task 4: Single-retry on non-zero claude exit (both agents)

**Files:**
- Modify: `tools/agents/hypothesis.py`
- Modify: `tools/agents/implement.py`

Anthropic occasionally returns 429s. The brief specifies one retry, then fail the slot — the orchestrator's broken-handling already logs cleanly.

- [ ] **Step 1: Wrap the claude invocation in `run_hypothesis_agent`**

In `tools/agents/hypothesis.py`, factor the existing claude `Popen` + watchdog + stream loop + return-code check into a helper, then call it twice on non-zero exit. Add this near the top of `run_hypothesis_agent` (after building `prompt`):

```python
def _run_claude_streaming(cmd: list, cwd: str, log_path: Path,
                          timeout_sec: int) -> tuple[int, bool]:
    """Run claude -p with NDJSON streaming, watchdog, and one-line summaries.

    Returns (returncode, timed_out). Caller decides retry/fail. Used by
    both run_hypothesis_agent and run_implementation_agent so the retry
    semantics are identical.
    """
    proc = subprocess.Popen(
        cmd, cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True, bufsize=1,
    )
    timed_out = {'flag': False}

    def watchdog():
        try:
            proc.wait(timeout=timeout_sec)
        except subprocess.TimeoutExpired:
            timed_out['flag'] = True
            proc.kill()

    threading.Thread(target=watchdog, daemon=True).start()

    with log_path.open("w") as log:
        for line in proc.stdout:
            log.write(line)
            log.flush()
            try:
                summary = _summarize_event(line)
            except Exception:
                summary = None
            if summary:
                print(f"  [claude] {summary}", flush=True)
    proc.wait()
    return proc.returncode, timed_out['flag']
```

Then in `run_hypothesis_agent`, replace the `Popen + watchdog + for-loop + proc.wait()` block with:

```python
    cmd = [
        "claude", "-p", prompt,
        "--dangerously-skip-permissions",
        "--output-format", "stream-json",
        "--verbose",
    ]
    HYPOTHESES_DIR.mkdir(parents=True, exist_ok=True)
    rc, timed_out = _run_claude_streaming(
        cmd, cwd=".", log_path=HYPOTHESIS_LOG, timeout_sec=HYPOTHESIS_TIMEOUT_SEC,
    )
    if rc != 0 and not timed_out:
        # Single retry. 429s and transient API errors are the most common
        # cause; a stuck-bug or wall-clock overrun (timed_out) we don't retry.
        print(f"  [claude] non-zero exit ({rc}); retrying once", flush=True)
        rc, timed_out = _run_claude_streaming(
            cmd, cwd=".", log_path=HYPOTHESIS_LOG, timeout_sec=HYPOTHESIS_TIMEOUT_SEC,
        )

    if timed_out:
        print(f"  [claude] TIMEOUT after {HYPOTHESIS_TIMEOUT_SEC}s — process killed",
              flush=True)
    elif rc != 0:
        raise subprocess.CalledProcessError(rc, cmd)
```

- [ ] **Step 2: Mirror the change in `tools/agents/implement.py`**

Add the same `_run_claude_streaming` helper to `tools/agents/implement.py` (or import from a new shared module — for simplicity, duplicate, matching the existing `_summarize_event` duplication). Replace the `Popen + watchdog + for-loop + proc.wait()` block with the helper call + single retry, mirroring Task 4 Step 1's shape.

```python
def _run_claude_streaming(cmd: list, cwd: str, log_path: Path,
                          timeout_sec: int) -> tuple[int, bool]:
    """See tools/agents/hypothesis.py — duplicated to keep the agent
    modules independent (same pattern as _summarize_event)."""
    proc = subprocess.Popen(
        cmd, cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True, bufsize=1,
    )
    timed_out = {'flag': False}

    def watchdog():
        try:
            proc.wait(timeout=timeout_sec)
        except subprocess.TimeoutExpired:
            timed_out['flag'] = True
            proc.kill()

    threading.Thread(target=watchdog, daemon=True).start()

    with log_path.open("w") as log:
        for line in proc.stdout:
            log.write(line)
            log.flush()
            try:
                summary = _summarize_event(line)
            except Exception:
                summary = None
            if summary:
                print(f"  [claude] {summary}", flush=True)
    proc.wait()
    return proc.returncode, timed_out['flag']
```

And in `run_implementation_agent`, replace the inline streaming block:

```python
    cmd = [
        "claude", "-p", prompt,
        "--dangerously-skip-permissions",
        "--output-format", "stream-json",
        "--verbose",
    ]
    rc, timed_out = _run_claude_streaming(
        cmd, cwd=worktree, log_path=log_path, timeout_sec=CLAUDE_TIMEOUT_SEC,
    )
    if rc != 0 and not timed_out:
        print(f"  [claude] non-zero exit ({rc}); retrying once", flush=True)
        rc, timed_out = _run_claude_streaming(
            cmd, cwd=worktree, log_path=log_path, timeout_sec=CLAUDE_TIMEOUT_SEC,
        )
    if timed_out:
        print(f"  [claude] TIMEOUT after {CLAUDE_TIMEOUT_SEC}s — process killed",
              flush=True)
```

- [ ] **Step 3: Lint-check both modules import cleanly**

```bash
python3 -c "from tools.agents.hypothesis import run_hypothesis_agent; from tools.agents.implement import run_implementation_agent; print('ok')"
```

Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add tools/agents/hypothesis.py tools/agents/implement.py
git commit -m "agents: single-retry on non-zero claude exit (429 mitigation)"
```

---

## Task 5: Serialize `append_log` with a module-level lock

**Files:**
- Modify: `tools/orchestrator.py`

`append_log` writes to `experiments/log.jsonl`, regenerates `progress.png`, and runs `git add` + `git commit`. With N concurrent slots finishing, two simultaneous `append_log` calls would race on git's index lock. Serialize via a `threading.Lock`.

- [ ] **Step 1: Add the lock import and wrap the body**

Edit `tools/orchestrator.py`. At the top of the file, add `import threading` and define the lock:

```python
import argparse, json, datetime, subprocess, re, threading
# ... existing imports ...

# Serializes append_log across concurrent tournament slots. The body of
# append_log writes log.jsonl, regenerates progress.png, then git-adds
# and commits both — three operations that all touch the index. Without
# this lock, two slots finishing within the same ~second would race on
# .git/index.lock and crash the round.
_LOG_LOCK = threading.Lock()
```

Replace the `append_log` function body to acquire the lock for its entire duration:

```python
def append_log(entry: dict):
    with _LOG_LOCK:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open('a') as f:
            f.write(json.dumps(entry) + '\n')
        plot_progress()
        subprocess.run(["git", "add", str(LOG_PATH)], check=True)
        plot_path = Path("experiments/progress.png")
        if plot_path.exists():
            subprocess.run(["git", "add", str(plot_path)], check=True)
        subprocess.run(
            ["git", "commit", "-m",
             f"log: {entry.get('id','unknown')} {entry.get('outcome','unknown')}"],
            check=True,
        )
```

- [ ] **Step 2: Verify nothing breaks the existing N=1 path**

```bash
python3 -c "from tools.orchestrator import append_log, _LOG_LOCK; print(type(_LOG_LOCK).__name__)"
```

Expected: `lock`.

- [ ] **Step 3: Commit**

```bash
git add tools/orchestrator.py
git commit -m "orchestrator: lock append_log so concurrent slots don't race on git index"
```

---

## Task 6: Eval-queue semaphores in `tools/tournament.py`

**Files:**
- Modify: `tools/tournament.py`

Add a `PhaseGate` context manager so per-phase capacity (`formal=1`, `fpga=1`) is uniform across slots. Lint/synth/build (Phase 3) and cosim (Phase 5) run unconstrained — they're either fast or already internally parallel.

- [ ] **Step 1: Append the eval-queue scaffolding to `tools/tournament.py`**

Add to the bottom of `tools/tournament.py`:

```python
import contextlib
import threading

# Per-phase capacity. Formal and FPGA each saturate cores (formal uses
# `make -j`, nextpnr is single-threaded but we already run 3 seeds per
# slot — N slots × 3 seeds would thrash). Phase 3 (lint/synth/build)
# and Phase 5 (cosim) are short or already-parallel, so no gate.
PHASE_CAPACITY: dict[str, int] = {
    "formal": 1,
    "fpga":   1,
}

# Module-level semaphores so all slots in a process share the same gates.
# Created lazily so test imports don't allocate them up front.
_phase_semaphores: dict[str, threading.Semaphore] = {}
_phase_semaphores_lock = threading.Lock()


def _get_phase_sem(phase: str) -> threading.Semaphore:
    with _phase_semaphores_lock:
        sem = _phase_semaphores.get(phase)
        if sem is None:
            sem = threading.Semaphore(PHASE_CAPACITY.get(phase, 1))
            _phase_semaphores[phase] = sem
        return sem


@contextlib.contextmanager
def phase_gate(phase: str):
    """Acquire the named phase's capacity semaphore. Use as `with phase_gate('formal'):`.
    A phase not in PHASE_CAPACITY defaults to capacity=1 (conservative)."""
    sem = _get_phase_sem(phase)
    sem.acquire()
    try:
        yield
    finally:
        sem.release()
```

- [ ] **Step 2: Add a unit test**

Append to `tools/test_tournament.py`:

```python
def test_phase_gate_serializes_under_capacity_one():
    """Two threads contending on the formal gate must not overlap."""
    import threading, time
    from tools.tournament import phase_gate

    overlap = {'count': 0, 'max': 0}
    in_section = {'n': 0}
    lock = threading.Lock()

    def worker():
        with phase_gate('formal'):
            with lock:
                in_section['n'] += 1
                overlap['max'] = max(overlap['max'], in_section['n'])
            time.sleep(0.05)
            with lock:
                in_section['n'] -= 1

    threads = [threading.Thread(target=worker) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert overlap['max'] == 1, "phase_gate('formal') failed to serialize"
```

- [ ] **Step 3: Run the test**

```bash
pytest tools/test_tournament.py::test_phase_gate_serializes_under_capacity_one -v
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add tools/tournament.py tools/test_tournament.py
git commit -m "tournament: phase_gate semaphores (formal=1, fpga=1)"
```

---

## Task 7: `run_tournament_round` — slot lifecycle + winner pick

**Files:**
- Modify: `tools/tournament.py`
- Modify: `tools/orchestrator.py`

The big task: assemble the round. Each slot is a `Future` that runs:
1. Hypothesis (uses pre-allocated ID + whitelist + category).
2. Schema validation.
3. Worktree create.
4. Implementation (in-worktree).
5. Sandbox check (orchestrator-level, on the worktree).
6. Phase 3 build (`emit_verilog`).
7. Phase 4 formal (under `phase_gate('formal')`).
8. Phase 5 cosim (no gate).
9. Phase 6 fpga (under `phase_gate('fpga')`).

Slot returns a draft entry dict with `outcome` provisionally set to `regression` (or `broken`). After all slots return, `pick_winner` chooses the round winner; the winner gets `outcome='improvement'` and `accept_worktree`; everyone else gets `destroy_worktree`. Then the coordinator drains a list of (entry, accept_msg) tuples through the `_LOG_LOCK`-serialized `append_log`.

- [ ] **Step 1: Add `run_slot` and `run_tournament_round` to `tools/tournament.py`**

Append:

```python
import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

# These are imported lazily inside the functions to avoid a circular
# import (tools.orchestrator imports from tools.tournament too).


def run_slot(
    slot: int,
    hyp_id: str,
    allowed_yaml_ids: list[str],
    log_tail: list,
    current_best: float,
    baseline: float,
    fixed_hyp_path: str | None,
) -> dict:
    """Run one tournament slot end-to-end. Returns a draft log entry.

    The entry has `outcome` set provisionally:
      - 'broken' / 'placement_failed' if any gate failed
      - 'regression' if all gates passed (winner-pick may upgrade to 'improvement')
    The coordinator decides the final outcome after all slots finish.
    """
    # Lazy imports to avoid circular import with tools.orchestrator.
    import yaml, jsonschema
    from tools.orchestrator import (
        emit_verilog, offlimits_changes, _read_notes, validate_hypothesis,
    )
    from tools.worktree import create_worktree, destroy_worktree
    from tools.agents.hypothesis import run_hypothesis_agent
    from tools.agents.implement import run_implementation_agent
    from tools.eval.formal import run_formal
    from tools.eval.cosim import run_cosim
    from tools.eval.fpga import run_fpga_eval

    category = category_for_slot(slot)
    print(f"  [slot {slot}] category={category} id={hyp_id}", flush=True)

    # Phase 1: hypothesis.
    if fixed_hyp_path:
        hyp_path = fixed_hyp_path
    else:
        try:
            hyp_path = run_hypothesis_agent(
                log_tail, current_best, baseline,
                hyp_id=hyp_id,
                allowed_yaml_ids=allowed_yaml_ids,
                category_hint=category,
            )
        except Exception as e:
            return {
                'id': hyp_id, 'title': f'(slot {slot} hypothesis-gen failed)',
                'category': category, 'outcome': 'broken',
                'formal_passed': False, 'cosim_passed': False,
                'error': f'hypothesis_gen_failed: {e}',
                'slot': slot,
            }

    # Phase 1b: schema validation.
    try:
        hyp = validate_hypothesis(hyp_path)
    except (jsonschema.ValidationError, FileNotFoundError, yaml.YAMLError) as e:
        return {
            'id': hyp_id, 'title': str(hyp_path), 'category': category,
            'outcome': 'broken', 'formal_passed': False, 'cosim_passed': False,
            'error': f'schema_error: {e}',
            'slot': slot,
        }

    # Phase 2: implement.
    worktree_id = hyp['id']  # could differ from hyp_id if agent ignored override
    worktree = create_worktree(worktree_id)
    print(f"  [slot {slot}] worktree={worktree}", flush=True)

    def broken(reason: str, detail: str = '') -> dict:
        destroy_worktree(worktree_id)
        return {
            **hyp, 'outcome': 'broken', 'formal_passed': False,
            'cosim_passed': False, 'error': f'{reason}: {detail}',
            'slot': slot,
        }

    if fixed_hyp_path and hyp.get('skip_implementation'):
        pass  # baseline-retest fixture path
    else:
        impl_ok = run_implementation_agent(hyp_path, worktree)
        if not impl_ok:
            return broken("implementation_compile_failed")

    sandbox_breaches = offlimits_changes(worktree)
    if sandbox_breaches:
        return broken("sandbox_violation",
                      f"agent touched off-limits paths: {sandbox_breaches}")

    # Phase 3: lint + synth + bench + cosim-build (no gate; fast).
    if not emit_verilog(worktree):
        return broken("build_failed")

    # Phase 4: formal (gated, formal=1).
    with phase_gate('formal'):
        formal = run_formal(worktree)
    if not formal['passed']:
        check  = formal.get('failed_check', '')
        detail = formal.get('detail', '')
        msg    = f"{check}\n{detail}".strip() if detail else check
        return broken("formal_failed", msg)

    # Phase 5: cosim (no gate).
    cosim = run_cosim(worktree)
    if not cosim['passed']:
        return broken("cosim_failed", cosim.get('failed_elf', ''))

    # Phase 6: FPGA (gated, fpga=1).
    with phase_gate('fpga'):
        fpga = run_fpga_eval(worktree)
    if fpga.get('placement_failed'):
        return {
            **hyp, 'outcome': 'placement_failed', 'formal_passed': True,
            'cosim_passed': True, 'error': 'placement_failed',
            'seeds': fpga.get('seeds'),
            'slot': slot,
        }
    if fpga.get('bench_failed'):
        return broken("coremark_failed", fpga.get('reason', ''))

    fitness = fpga['fitness']
    delta   = ((fitness - current_best) / current_best * 100) if current_best > 0 else 0.0
    vs_base = ((fitness - baseline) / baseline * 100) if baseline > 0 else 0.0

    return {
        **hyp,
        # Provisional. Coordinator upgrades winner to 'improvement'.
        'outcome':       'regression',
        'fitness':       fitness,
        'delta_pct':     round(delta, 2),
        'vs_baseline':   round(vs_base, 2),
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
        'implementation_notes': _read_notes(worktree),
        'timestamp':     datetime.datetime.utcnow().isoformat(),
        'slot':          slot,
    }


def run_tournament_round(
    round_id: int,
    tournament_size: int,
    log: list,
    fixed_hyp_paths: list[str] | None = None,
) -> list[dict]:
    """Run one round of N slots in parallel; return list of log entries."""
    from tools.orchestrator import (
        current_best as _current_best,
        baseline_fitness as _baseline,
        append_log,
    )
    from tools.worktree import accept_worktree, destroy_worktree

    best     = _current_best(log)
    baseline = _baseline(log)
    print(f"\n{'='*60}\nRound {round_id}  |  slots={tournament_size}  |  current best={best:.2f}\n{'='*60}", flush=True)

    today = datetime.date.today().strftime("%Y%m%d")
    # First-seq picker: continue numbering from existing files in
    # experiments/hypotheses/ for the day so IDs stay monotonic across
    # rounds within a single day. _next_id-style logic, hoisted up.
    HYPOTHESES_DIR = Path("experiments/hypotheses")
    HYPOTHESES_DIR.mkdir(parents=True, exist_ok=True)
    existing = list(HYPOTHESES_DIR.glob(f"hyp-{today}-*.yaml"))
    first_seq = len(existing) + 1
    hyp_ids = allocate_round_ids(round_id, tournament_size, today=today,
                                 first_seq=first_seq)
    print(f"  pre-allocated IDs: {hyp_ids}", flush=True)

    # Validate fixed_hyp_paths shape.
    if fixed_hyp_paths is not None:
        if len(fixed_hyp_paths) != tournament_size:
            raise ValueError(
                f"--from-hypothesis count {len(fixed_hyp_paths)} != tournament_size {tournament_size}"
            )
    else:
        fixed_hyp_paths = [None] * tournament_size

    # Fan out N slots in parallel (claude calls + worktree builds).
    entries: list[dict] = []
    with ThreadPoolExecutor(max_workers=tournament_size) as pool:
        futures = {
            pool.submit(
                run_slot, slot, hyp_ids[slot], hyp_ids,
                log, best, baseline, fixed_hyp_paths[slot],
            ): slot
            for slot in range(tournament_size)
        }
        for fut in as_completed(futures):
            entry = fut.result()
            entry['round_id'] = round_id
            entries.append(entry)
            print(f"  [slot {entry['slot']}] returned outcome={entry['outcome']}", flush=True)

    # Sort by slot for stable log ordering (asthetic, helps grep).
    entries.sort(key=lambda e: e['slot'])

    # Winner pick: highest-fitness slot whose fitness > start-of-round best.
    winner = pick_winner(entries, current_best=best)

    # Apply outcomes + accept/destroy worktrees.
    for entry in entries:
        if entry is winner:
            entry['outcome'] = 'improvement'
            msg = (f"{entry['id']}: {entry['title']} "
                   f"(+{entry.get('delta_pct', 0):.1f}%)")
            try:
                accept_worktree(entry['id'], msg)
            except Exception as e:
                # Worktree merge failed (shouldn't happen with ff-only) —
                # downgrade to regression and keep going so the log still lands.
                print(f"  [coordinator] accept_worktree({entry['id']}) failed: {e}",
                      flush=True)
                entry['outcome'] = 'regression'
        elif entry.get('fitness') is not None and entry['outcome'] == 'regression':
            destroy_worktree(entry['id'])
        # 'broken' / 'placement_failed' slots already destroyed their worktree.

    # Append log entries one-by-one through the lock-serialized append_log.
    for entry in entries:
        append_log(entry)

    print(f"\n  Round {round_id} complete: " +
          ", ".join(f"slot {e['slot']}={e['outcome']}" for e in entries) +
          (f" (winner: slot {winner['slot']})" if winner else " (no winner)"),
          flush=True)
    return entries
```

- [ ] **Step 2: Wire `run_tournament_round` into `tools/orchestrator.py`**

Edit `tools/orchestrator.py`. Add the import near the existing `from tools.plot import plot_progress` line:

```python
from tools.tournament import run_tournament_round
```

Replace the `for i in range(...)` block at the bottom of `main()`:

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
    args = parser.parse_args()

    if args.report:
        run_report()
        return

    fixed = None
    if args.from_hypothesis:
        fixed = [p.strip() for p in args.from_hypothesis.split(',')]

    # Round numbering: continue from the highest round_id in the log + 1
    # (so multiple `make next` invocations don't all label themselves
    # round 1). New if-no-prior-rounds: start at 1.
    log = read_log()
    prior_rounds = [e.get('round_id', 0) for e in log if isinstance(e.get('round_id'), int)]
    next_round = (max(prior_rounds) + 1) if prior_rounds else 1

    for r in range(args.iterations):
        round_id = next_round + r
        log = read_log()
        run_tournament_round(round_id, args.tournament_size, log,
                             fixed_hyp_paths=fixed)
```

- [ ] **Step 3: Remove the now-dead `run_iteration` function (or keep as deprecated)**

For minimum churn, **delete `run_iteration` entirely**. Anything that previously called it (just `main`) now goes through `run_tournament_round`. Search to confirm no other caller:

```bash
grep -rn "run_iteration" tools/ test/ Makefile 2>/dev/null
```

Expected: only `tools/orchestrator.py:def run_iteration` (which you're about to delete). If anything else turns up, address before continuing.

Delete the `run_iteration` function (`tools/orchestrator.py:152-288` in the pre-edit numbering).

- [ ] **Step 4: Sanity-import**

```bash
python3 -c "from tools.orchestrator import main, append_log, run_tournament_round; print('ok')"
```

Expected: `ok`.

- [ ] **Step 5: Commit**

```bash
git add tools/orchestrator.py tools/tournament.py
git commit -m "tournament: run_tournament_round — N parallel slots + winner-takes-all"
```

---

## Task 8: Plot.py round-banding

**Files:**
- Modify: `tools/plot.py`

When entries carry `round_id`, draw a translucent vertical band per round so the chart visually groups slots within a tournament round. Skip the banding if no entries have `round_id` (back-compat with the legacy single-iteration log).

- [ ] **Step 1: Add the banding pass before the scatter loop**

Edit `tools/plot.py` and insert this block right after `fig, ax = plt.subplots(...)` (currently line 48), BEFORE the `for i, e in enumerate(entries):` scatter:

```python
    # Round-banding: shade vertical regions for entries that share a round_id
    # (tournament mode). Legacy entries (no round_id) get no band.
    round_groups: dict[int, list[int]] = {}
    for i, e in enumerate(entries):
        rid = e.get('round_id')
        if isinstance(rid, int):
            round_groups.setdefault(rid, []).append(i)
    for rid, idxs in round_groups.items():
        if len(idxs) < 2:
            continue  # single-slot round — no need to band
        x0, x1 = min(idxs) - 0.4, max(idxs) + 0.4
        # Faint blue band; alternating shade by round parity for legibility.
        shade = '#3498db' if rid % 2 == 0 else '#9b59b6'
        ax.axvspan(x0, x1, color=shade, alpha=0.08, zorder=0)
```

- [ ] **Step 2: Verify the chart renders without crashing on the legacy log**

```bash
python3 -c "from tools.plot import plot_progress; plot_progress(); print('ok')"
```

Expected: `ok`. (`experiments/progress.png` regenerates; the existing single-entry log has no `round_id`, so no banding — back-compat verified.)

- [ ] **Step 3: Commit**

```bash
git add tools/plot.py
git commit -m "plot: round-banding for tournament entries"
```

---

## Task 9: N=1 regression — recreate the no-op fixture and verify 282.82

**Files:**
- Create (locally, gitignored): `experiments/hypotheses/hyp-20260427-002-r1s0.yaml`

The brief specifies the regression fixture is `hyp-20260427-001.yaml`, but that ID is already used by the baseline log entry. Use `hyp-20260427-002-r1s0` (the next available ID under the new tournament-mode pattern) so the schema validates and IDs don't collide.

- [ ] **Step 1: Write the no-op fixture**

```bash
mkdir -p experiments/hypotheses
cat > experiments/hypotheses/hyp-20260427-002-r1s0.yaml <<'EOF'
id: hyp-20260427-002-r1s0
title: "Baseline retest (no-op, tournament-mode N=1 regression fixture)"
category: micro_opt
motivation: |
  Regression test for the speculative-tournament loop refactor.
  Runs the full eval pipeline against the unchanged baseline RTL with
  tournament_size=1; the resulting log entry must match the locked
  baseline numbers (fitness=282.82, fmax=127.03, lut4=9563, ff=1866,
  seeds=[128.72, 127.03, 123.02], 53/53 formal, all CRCs match).
hypothesis: |
  No RTL changes. Exercises the worktree -> emit_verilog -> formal ->
  cosim -> fpga path on the existing rtl/*.sv via the tournament code
  with N=1.
expected_impact:
  fitness_delta_pct: 0
  confidence: high
changes:
  - file: rtl/core.sv
    description: |
      Sentinel — no real change. skip_implementation:true bypasses the
      implementation agent so the file path is metadata only; it just has
      to satisfy the schema's rtl/<file> pattern.
skip_implementation: true
EOF
```

- [ ] **Step 2: Run N=1 against the fixture**

```bash
python3 -m tools.orchestrator \
  --iterations 1 \
  --tournament-size 1 \
  --from-hypothesis experiments/hypotheses/hyp-20260427-002-r1s0.yaml \
  2>&1 | tee /tmp/n1_regression.log
```

Expected: full pipeline runs (formal ~5-10 min, fpga ~10-20 min). At end, a log entry should be appended with `outcome=improvement` (since the no-op design ties baseline; the winner picker upgrades it because `fitness > current_best` requires `>` strict — so this should actually be `outcome=regression` with `delta_pct=0.0`).

Wait — that's a behavioral change. The OLD `run_iteration` used `outcome = 'improvement' if fitness > best else 'regression'`. Under that rule, the original baseline log entry (fitness=282.82) was logged as 'improvement' because `best` was 0 (empty log). On a retest with `best=282.82`, the new entry would be `regression` because 282.82 is not > 282.82. So the regression test should expect `outcome=regression`, `fitness=282.82`, `delta_pct=0.0`. Confirm by reading the appended log entry:

```bash
tail -1 experiments/log.jsonl | python3 -c "
import json, sys
e = json.loads(sys.stdin.read())
expected = {'fitness': 282.82, 'fmax_mhz': 127.03, 'lut4': 9563, 'ff': 1866}
got      = {k: e.get(k) for k in expected}
mismatches = [(k, expected[k], got[k]) for k in expected if expected[k] != got[k]]
if mismatches:
    print('REGRESSION TEST FAILED:'); 
    for k, exp, got_ in mismatches:
        print(f'  {k}: expected {exp}, got {got_}')
    sys.exit(1)
print(f'REGRESSION OK: fitness={e[\"fitness\"]} fmax={e[\"fmax_mhz\"]} lut4={e[\"lut4\"]} ff={e[\"ff\"]}')
print(f'  outcome={e[\"outcome\"]} round_id={e.get(\"round_id\")} slot={e.get(\"slot\")}')
print(f'  formal_passed={e[\"formal_passed\"]} cosim_passed={e[\"cosim_passed\"]}')
"
```

Expected output:

```
REGRESSION OK: fitness=282.82 fmax=127.03 lut4=9563 ff=1866
  outcome=regression round_id=2 slot=0
  formal_passed=True cosim_passed=True
```

(round_id=2 because the existing baseline entry has no round_id, so `next_round` defaults to 1+1=... actually re-check: the orchestrator computes `next_round = max(prior_rounds) + 1 if prior_rounds else 1`. The baseline has no `round_id` field so it's filtered out; `prior_rounds` is empty → `next_round = 1`. So the entry should have `round_id=1`. Adjust expectation in the assertion:

```python
expected_round_id = 1
```

If the assertion runs with `round_id=1`, the regression test passes.

- [ ] **Step 3: If the regression numbers match, commit the test artifacts**

The fixture is gitignored, so nothing to commit there. The log entry IS tracked — `append_log` already committed it. Verify:

```bash
git log -2 --oneline
```

Expected: a `log: hyp-20260427-002-r1s0 regression` commit on top.

- [ ] **Step 4: If numbers DON'T match, STOP**

A mismatch means the tournament refactor changed semantics. Don't chase the symptom — diff the appended entry against `experiments/log.jsonl` line 1 field-by-field, identify which field drifted, and fix the root cause in `run_slot` / `run_tournament_round`. Common culprits: `vs_baseline` math (denominator), `delta_pct` sign, `outcome` derivation, missing `slot=0`/`round_id=1` fields.

---

## Task 10: N=3 live tournament round

**Files:** none (this is an integration check)

A real round with three claude-driven slots. Expected wall-clock: ~30-60 minutes total (each slot's hypothesis ~2-5 min; implement ~5-15 min; eval-queue serialization adds ~30 min × 3 for fpga + ~10 min × 3 for formal, but fpga-on-slot-0 overlaps with formal-on-slot-1 so it's not a strict 3× multiplier).

- [ ] **Step 1: Confirm pre-flight**

```bash
which claude verilator yosys nextpnr-himbaechel riscv32-unknown-elf-gcc
test -d formal/riscv-formal && echo "riscv-formal: present" || echo "riscv-formal: MISSING — run setup.sh"
git status --porcelain  # should be clean before launching
```

All five binaries must resolve; `riscv-formal` directory must exist; main repo must be clean.

- [ ] **Step 2: Run one tournament round**

```bash
python3 -m tools.orchestrator --iterations 1 --tournament-size 3 \
  2>&1 | tee /tmp/n3_round.log
```

- [ ] **Step 3: Verify the round shape**

```bash
tail -3 experiments/log.jsonl | python3 -c "
import json, sys
entries = [json.loads(l) for l in sys.stdin]
assert len(entries) == 3, f'expected 3 entries, got {len(entries)}'
rounds = {e.get('round_id') for e in entries}
assert len(rounds) == 1, f'all 3 entries should share a round_id, got {rounds}'
slots = sorted(e.get('slot') for e in entries)
assert slots == [0, 1, 2], f'slots should be [0,1,2], got {slots}'
improvements = [e for e in entries if e.get('outcome') == 'improvement']
assert len(improvements) <= 1, f'at most one winner, got {len(improvements)}'
cats = sorted(e.get('category') for e in entries)
print(f'Round shape OK: round_id={rounds.pop()} slots={slots}')
print(f'  outcomes: {[e[\"outcome\"] for e in entries]}')
print(f'  categories: {cats}')
print(f'  winner: ' + (improvements[0]['id'] if improvements else '(none)'))
"
```

Expected: `Round shape OK: round_id=N slots=[0, 1, 2]` with three categories.

- [ ] **Step 4: Verify worktree cleanup**

```bash
ls experiments/worktrees/ 2>/dev/null
```

Expected: empty (no leftover loser worktrees) OR just the merged winner's directory if a future commit removed it differently — read `accept_worktree`/`destroy_worktree` to confirm. Per current `worktree.py`, accept also calls `destroy_worktree`, so the dir should be empty.

- [ ] **Step 5: If the round produced no winner (all 3 < baseline), that's still a valid pass**

The round did its job: ran 3 hypotheses, none beat the baseline, log captured 3 regressions, no accept committed. `progress.png` should show 3 dots clustered around-or-below the existing champion line, with a translucent band grouping them.

- [ ] **Step 6: Commit any leftover state**

`append_log` already committed the log entries; no further commit needed unless something is left dirty. `git status` should be clean.

---

## Task 11: N=3 with one slot deliberately broken

**Files:** none (integration check)

Confirm the round survives a sandbox-violation breach in slot 0 without killing slots 1 and 2. The cleanest way to deterministically inject the failure is to monkey-patch the orchestrator's sandbox check so the first call (slot 0) returns a fake breach; subsequent calls (slots 1, 2) use the real check.

- [ ] **Step 1: Run the round with the patched sandbox check**

```bash
python3 - <<'PY'
import tools.orchestrator as orch
import tools.tournament as tnm
from tools.orchestrator import read_log

original = orch.offlimits_changes

def patched(worktree):
    # Key on worktree path so the injected breach lands on slot 0 deterministically,
    # not whichever slot's `offlimits_changes` happened to fire first.
    if 'r1s0' in str(worktree) or str(worktree).endswith('s0'):
        return ['tools/orchestrator.py']  # simulated breach
    return original(worktree)

orch.offlimits_changes = patched
# run_slot does `from tools.orchestrator import offlimits_changes` lazily
# inside the function body. Since our monkey-patch rebinds the module
# attribute BEFORE run_tournament_round is called, the lazy import
# resolves to the patched version.

log = read_log()
prior = [e.get('round_id', 0) for e in log if isinstance(e.get('round_id'), int)]
rid = (max(prior) + 1) if prior else 1
tnm.run_tournament_round(rid, 3, log, fixed_hyp_paths=None)
PY
```

Wall-clock: same as Task 10 (~30-60 min) since slots 1 and 2 still run the full pipeline. Slot 0 short-circuits at sandbox check.

Note: slots 1 and 2 will spin up real claude calls (no fixture path). If you want the test to also avoid real-claude cost on slots 1 and 2, write two extra no-op fixtures and pass `fixed_hyp_paths=['<bad>', '<noop1>', '<noop2>']` — but then slot 0's breach must come from a fixture that points the agent at off-limits work, which requires `skip_implementation: false` and a prompt-induced breach. The monkey-patch is simpler and deterministic; use it.

- [ ] **Step 2: Confirm broken-slot did NOT crash the round**

```bash
tail -3 experiments/log.jsonl | python3 -c "
import json, sys
entries = [json.loads(l) for l in sys.stdin]
assert len(entries) == 3, f'expected 3 entries, got {len(entries)}'
broken   = [e for e in entries if e.get('outcome') == 'broken']
assert len(broken) >= 1, f'expected at least 1 broken slot, got 0'
broken_slot = broken[0]
assert broken_slot.get('slot') == 0, f'expected broken slot to be slot 0, got {broken_slot.get(\"slot\")}'
assert 'sandbox_violation' in (broken_slot.get('error') or ''), \
    f'expected sandbox_violation error, got {broken_slot.get(\"error\")}'
others = [e for e in entries if e.get('slot') != 0]
assert len(others) == 2, f'expected 2 other slots, got {len(others)}'
print('Broken-slot survival OK: slot 0 broken (sandbox_violation), slots 1&2 ran to completion')
print(f'  outcomes: {[(e[\"slot\"], e[\"outcome\"]) for e in sorted(entries, key=lambda x: x[\"slot\"])]}')
"
```

Expected: `Broken-slot survival OK: ...`.

- [ ] **Step 3: No commit needed (the run already auto-committed log entries)**

Verify:

```bash
git status
```

Expected: `nothing to commit, working tree clean`.

---

## Task 12: README + log.jsonl back-compat audit

**Files:**
- Modify: `README.md` (add a one-paragraph mention of tournament mode)

- [ ] **Step 1: Confirm the legacy single-entry log still parses through the new code**

```bash
python3 -c "
from tools.orchestrator import read_log
log = read_log()
for e in log[:1]:
    # Legacy entries have no round_id/slot — should be missing or None.
    assert 'round_id' not in e or e['round_id'] is None
print('Legacy log compatibility OK')
"
```

Expected: `Legacy log compatibility OK`.

- [ ] **Step 2: Confirm `tools.plot` renders mixed old+new entries**

After Task 9 (N=1 regression) ran, the log has 1 legacy + 1 tournament entry. After Task 10 (N=3 round), 1 legacy + 1+3 tournament. Regenerate the chart and visually inspect (or just check it doesn't crash):

```bash
python3 -c "from tools.plot import plot_progress; plot_progress(); print('ok')"
```

Expected: `ok`. Open `experiments/progress.png` and confirm: (a) baseline dot is visible at fitness=282.82; (b) tournament rounds have the translucent band; (c) champion path stays monotonic.

- [ ] **Step 3: Add a paragraph to README.md under "Quickstart"**

Open `README.md` and after the line `make loop N=10 ...` (currently line 65), insert:

```markdown
make next                 # one tournament round (default 3 slots in parallel)
make loop N=10            # 10 tournament rounds
```

…and just below the code block, add a sentence:

```markdown
Each tournament round runs N hypotheses concurrently (claude-driven, network-bound),
serializes the heavy eval phases (formal=1, fpga=1) through a queue, and accepts
only the round's highest-fitness winner. Configure with `--tournament-size N`
(default 3); `N=1` reproduces the prior sequential behavior exactly.
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "README: document tournament-mode loop"
```

---

## Self-review checklist

After completing all 12 tasks, run through this checklist:

1. **N=1 regression matches baseline numbers exactly** (Task 9 Step 2). If `fitness ≠ 282.82`, the refactor broke the contract — debug before declaring done.
2. **Schema regex accepts both legacy and `-rRsS` forms** (Task 1 Step 2).
3. **`pytest tools/test_tournament.py -v` is green** (Tasks 2 + 6).
4. **`grep -rn run_iteration tools/ test/ Makefile`** returns nothing (Task 7 Step 3).
5. **`tools/plot.py` renders without crash on legacy + new entries** (Task 12 Step 2).
6. **`progress.png` shows the new round-banding** (Task 12 Step 2 visual).
7. **All commits leave the repo in a runnable state** (`git status` clean after each).

## Deferred / out of scope

- Cross-slot rtl/ pollution (one slot's misbehaving agent dirtying main's rtl/, tripping all slots' sandbox checks): the pre-allocated whitelist handles the common YAML-collision case; the rare cross-rtl pollution is an existing limitation, documented in `tools/agents/hypothesis.py` comments.
- Snapshot-diff sandbox-check (more precise per-slot attribution): considered but deferred — the brief explicitly recommends the simpler whitelist regex. Revisit if the broken-slot survival test (Task 11) shows false-positive cross-pollution under real load.
- Cron / `make tournament` Makefile target: not required by the brief; `make next` already runs one iteration via the new tournament code at the default N=3.
- `--from-hypothesis` with skip-implementation slots in tournament mode: works for N=1 (Task 9). For N>1 with mixed real-and-fixed slots, the comma-separated parser supports it but isn't exercised; revisit when needed.
