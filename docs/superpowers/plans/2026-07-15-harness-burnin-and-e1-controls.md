# Harness Burn-in + E1 Attribution Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the bench harness fail fast and preserve forensics (so no more mystery rep failures), then add the two no-scaffold control agents (random-mutation, naive-LLM) that the v2 paper's attribution claim depends on.

**Architecture:** All changes live in `tools/` (runner, runtime dispatch, agents) plus new model YAMLs and prereg files. The random agent mirrors `tools/agents/static_agent.py` exactly (prompt-sniffing CLI invoked via `AGENT_PROVIDER=random`); the naive-LLM arm is a prompt-profile switch threaded through env (`BENCH_PROMPT_PROFILE`), not a new agent. Pre-flight and forensics changes are additive to `tools/bench/runner.py`.

**Tech Stack:** Python 3.13, pytest, PyYAML, git, verilator/yosys/nextpnr-himbaechel/sby/bitwuzla (checked, not modified).

## Context: what the sol diagnosis found (2026-07-15)

Recorded here so task rationale is self-contained. Evidence: `bench/results.jsonl`, commit `6149308`, surviving clones under `.claude/bench-runs/gpt-5_6-sol-rep*/`.

- sol rep2+rep3, first attempt (2026-07-11 20:22:15Z): both started the same second rep1 finished, both died with `orchestrator_exit: 1` in seconds, empty agent logs. The clones were overwritten by the retry, so the root cause is UNPROVEN. Candidates: missing-tool env (orchestrator `SystemExit` paths in `_run_baseline_retest`), or clone/publish race with the unattended publisher committing at that same second.
- sol rep2+rep3, retry (20:29:51Z): ran 4.5 h, then both received SIGTERM (`exit -15`) at 01:00:57Z, which matches commit `6d1a17c` ("publish sol rep2, rep3") authored 22:01:27 local within 30 s. Conclusion: manual abort, then published as failed. The log tail shows the codex agent unable to run `sby` (hunting a toolchain in `~/bonetto/riscv-autoarch`), and codex sandbox rejections of `/private/tmp` writes.
- Structural gaps regardless of root cause: (1) `orchestrator.log` is never copied out of the clone, so failures destroy their own evidence unless `--keep-clones`; (2) no pre-flight toolchain check, so a bad environment burns reps; (3) the runner labels every non-zero orchestrator exit `" make exit=N"`, which is wrong (nothing runs make) and misled the investigation.

## Global Constraints

- Branch: all work on `bench-v2`. Never commit to `main`.
- CLAUDE.md's don't-touch list binds *hypothesis agents*, not maintainers; we may edit `tools/`, but must NOT weaken any eval gate, invariant, or fence.
- Do not modify: `formal/`, `schemas/`, `bench/programs/`, `test/cosim/`, `fpga/`, existing rows in `bench/results.jsonl`.
- No em-dashes in any user-facing text, comments, or docs (project rule).
- Commit prefix convention from history: `tools:`, `bench:`, `research:`, `docs:`.
- Tests run with: `python3 -m pytest tools/ -q` (from repo root).
- Burn-in runs write to scratch paths, never to `bench/results.jsonl`.

---

### Task 1: De-track compiled bytecode

**Files:**
- Modify: `.gitignore`
- Delete from index (not disk): 6 tracked `.pyc` files (see step 1)

**Interfaces:** none (hygiene). `clone_fixture`'s assume-unchanged defense in `tools/bench/runner.py:287-300` stays (harmless, still guards historical fixture refs).

- [ ] **Step 1: Untrack the pyc files**

```bash
cd /Users/bonetto/bonetto/auto-arch-tournament
git rm --cached tools/__pycache__/__init__.cpython-313.pyc \
  tools/bench/__pycache__/__init__.cpython-313.pyc \
  tools/bench/__pycache__/build_fixture.cpython-313.pyc \
  tools/bench/__pycache__/fence_validator.cpython-313.pyc \
  tools/bench/__pycache__/report.cpython-313.pyc \
  tools/bench/__pycache__/runner.cpython-313.pyc
```

Expected: 6 `rm 'tools/...'` lines. Files stay on disk.

- [ ] **Step 2: Ignore them forever**

Check `grep -n "__pycache__" .gitignore`; if absent, append:

```
__pycache__/
*.pyc
```

- [ ] **Step 3: Verify clean status and commit**

Run: `git status --porcelain | grep pyc` -> only `D ` (staged deletions), no `??` for pyc.

```bash
git commit -m "tools: stop tracking compiled bytecode"
```

---

### Task 2: Preserve failure forensics in the runner

**Files:**
- Modify: `tools/bench/runner.py` (run_one_job, ~line 935-985)
- Create: `tools/bench/preflight.py` (fingerprint half; checks come in Task 3)
- Test: `tools/bench/test_preflight.py`

**Interfaces:**
- Produces: `preflight.env_fingerprint() -> dict` with keys `path` (str) and `tools` (dict[str, str | None]); `preflight.REQUIRED_TOOLS: tuple[str, ...]`.
- Produces: per-rep `bench/<model>/rep<N>/orchestrator.log` and `env.json` (consumed by humans and by the paper's failure-taxonomy audit).

- [ ] **Step 1: Write failing tests**

Create `tools/bench/test_preflight.py`:

```python
"""Tests for tools/bench/preflight.py."""
import json
import shutil
from pathlib import Path

from tools.bench import preflight


def test_required_tools_frozen():
    assert preflight.REQUIRED_TOOLS == (
        "verilator", "yosys", "nextpnr-himbaechel", "sby", "bitwuzla",
    )


def test_env_fingerprint_shape(monkeypatch):
    monkeypatch.setattr(shutil, "which",
                        lambda t: f"/fake/bin/{t}" if t != "sby" else None)
    fp = preflight.env_fingerprint()
    assert set(fp) == {"path", "tools"}
    assert fp["tools"]["yosys"] == "/fake/bin/yosys"
    assert fp["tools"]["sby"] is None


def test_fingerprint_is_json_serializable(monkeypatch):
    monkeypatch.setattr(shutil, "which", lambda t: None)
    json.dumps(preflight.env_fingerprint())
```

- [ ] **Step 2: Run tests, verify failure**

Run: `python3 -m pytest tools/bench/test_preflight.py -q`
Expected: FAIL / error, `No module named 'tools.bench.preflight'`.

- [ ] **Step 3: Create `tools/bench/preflight.py`**

```python
"""Toolchain pre-flight and environment fingerprinting for the bench runner.

Motivated by the 2026-07-11 gpt-5_6-sol rep2/rep3 startup failures: two
reps died in seconds with orchestrator exit 1 and no surviving evidence.
A rep costs hours of wall clock; refusing to start against a broken
toolchain and snapshotting the env are both far cheaper than one wasted rep.
"""
from __future__ import annotations

import os
import shutil

# Every external binary the eval gates shell out to, per grep of
# Makefile, formal/run_all.sh, and fpga/scripts/ (2026-07-15):
# verilator (lint + cosim), yosys (synth), nextpnr-himbaechel (P&R),
# sby + bitwuzla (riscv-formal).
REQUIRED_TOOLS: tuple[str, ...] = (
    "verilator", "yosys", "nextpnr-himbaechel", "sby", "bitwuzla",
)


def env_fingerprint() -> dict:
    """Snapshot of PATH and resolved tool paths, for per-rep forensics."""
    return {
        "path": os.environ.get("PATH", ""),
        "tools": {t: shutil.which(t) for t in REQUIRED_TOOLS},
    }


def missing_tools() -> list[str]:
    return [t for t in REQUIRED_TOOLS if shutil.which(t) is None]


def report() -> str:
    lines = ["[preflight] toolchain:"]
    for t in REQUIRED_TOOLS:
        p = shutil.which(t)
        lines.append(f"  {t:20s} {p or 'MISSING'}")
    return "\n".join(lines)
```

- [ ] **Step 4: Run tests, verify pass**

Run: `python3 -m pytest tools/bench/test_preflight.py -q`
Expected: 3 passed.

- [ ] **Step 5: Wire forensics into run_one_job**

In `tools/bench/runner.py`:

(a) Add import near the top with the other local imports:

```python
from tools.bench import preflight
```

(b) In `run_one_job`, right after the clone succeeds (after the
`clone_fixture` try/except, ~line 830), snapshot the env:

```python
    # Forensics: snapshot the environment this rep will run under.
    fp_path = clone / ".tmp" / "env.json"
    fp_path.parent.mkdir(parents=True, exist_ok=True)
    fp_path.write_text(json.dumps(preflight.env_fingerprint(), indent=2) + "\n")
```

(c) In the finalize section (step 4 of run_one_job, after the
`agent_concat` copy, ~line 973), always copy the orchestrator log and
fingerprint out of the clone:

```python
    # Forensics survive clone deletion: without this, a failed rep's
    # orchestrator.log dies with the clone (the sol rep2/3 startup
    # failures were undiagnosable for exactly this reason).
    if orch_log_path.is_file():
        shutil.copy2(orch_log_path, out_dir / "orchestrator.log")
    if fp_path.is_file():
        shutil.copy2(fp_path, out_dir / "env.json")
```

(d) Fix the misleading failure label (~line 982). Replace:

```python
        row["notes"] = (row["notes"] or "") + f" make exit={row['orchestrator_exit']}"
```

with:

```python
        row["notes"] = (row["notes"] or "") + (
            f" orchestrator exit={row['orchestrator_exit']}"
            f" (see rep dir orchestrator.log)"
        )
```

- [ ] **Step 6: Check nothing parses the old label**

Run: `grep -rn "make exit" tools/ site/ --include=*.py --include=*.html`
Expected: only the runner line you just changed (now gone) and possibly
historical strings in `bench/` data (do not touch data). If
`tools/bench/report.py` or `tools/site/build.py` match on `make exit`,
widen their match to `r"(make|orchestrator) exit"` so old rows still parse.

- [ ] **Step 7: Full test suite + commit**

Run: `python3 -m pytest tools/ -q`
Expected: all pass (pre-existing suite + 3 new).

```bash
git add tools/bench/preflight.py tools/bench/test_preflight.py tools/bench/runner.py
git commit -m "tools: preserve per-rep forensics (orchestrator.log, env fingerprint), fix failure label"
```

---

### Task 3: Toolchain pre-flight gate in the runner

**Files:**
- Modify: `tools/bench/runner.py` (main, ~line 1008-1060)
- Modify: `tools/bench/test_preflight.py`

**Interfaces:**
- Consumes: `preflight.missing_tools()`, `preflight.report()` from Task 2.
- Produces: runner exits 2 with a clear message before any clone when tools are missing; `--skip-preflight` escape hatch.

- [ ] **Step 1: Write failing test**

Append to `tools/bench/test_preflight.py`:

```python
def test_missing_tools_lists_only_absent(monkeypatch):
    monkeypatch.setattr(
        shutil, "which",
        lambda t: None if t in ("sby", "bitwuzla") else f"/fake/{t}")
    assert preflight.missing_tools() == ["sby", "bitwuzla"]


def test_report_marks_missing(monkeypatch):
    monkeypatch.setattr(shutil, "which", lambda t: None)
    out = preflight.report()
    assert out.count("MISSING") == len(preflight.REQUIRED_TOOLS)
```

- [ ] **Step 2: Run tests**

Run: `python3 -m pytest tools/bench/test_preflight.py -q`
Expected: PASS already (functions exist from Task 2). These tests pin the
behavior the runner wiring depends on; if they pass immediately, proceed.

- [ ] **Step 3: Wire into main()**

In `tools/bench/runner.py` `main()`:

(a) Add the flag after `--dry-run` (~line 1029):

```python
    ap.add_argument("--skip-preflight", action="store_true",
                    help="skip the toolchain pre-flight check (debug only)")
```

(b) Immediately after `args = ap.parse_args()` (~line 1030), before
`load_models`:

```python
    if not args.skip_preflight:
        missing = preflight.missing_tools()
        if missing:
            print(f"[bench] FATAL: required tools not on PATH: {missing}",
                  file=sys.stderr)
            print(preflight.report(), file=sys.stderr)
            print("[bench] source setup.sh (or fix PATH) and retry; "
                  "--skip-preflight overrides.", file=sys.stderr)
            return 2
        print(preflight.report())
```

- [ ] **Step 4: Manual verification, both directions**

Run: `python3 -m tools.bench.runner --dry-run --models tools/bench/models-static.yaml`
Expected: `[preflight] toolchain:` block with 5 resolved paths, then the
normal dry-run output.

Run: `env PATH=/usr/bin:/bin python3 -m tools.bench.runner --dry-run --models tools/bench/models-static.yaml`
Expected: exit 2, `FATAL: required tools not on PATH: [...]`.

- [ ] **Step 5: Commit**

```bash
git add tools/bench/runner.py tools/bench/test_preflight.py
git commit -m "tools: refuse to start reps against a broken toolchain (preflight gate)"
```

---

### Task 4: Random-mutation control agent (E1b)

**Files:**
- Create: `tools/agents/random_agent.py`
- Create: `tools/agents/test_random_agent.py`
- Modify: `tools/agents/_runtime.py` (VALID_PROVIDERS ~line 39, build_agent_cmd ~line 309)
- Modify: `tools/bench/runner.py` (make_env_for_job ~line 441)
- Create: `tools/bench/models-random.yaml`

**Interfaces:**
- Consumes: orchestrator prompts (same phase-detection strings as `static_agent.py:122-126`); `RANDOM_AGENT_SEED` env var (set by runner: `100 + rep`).
- Produces: provider `"random"` usable in model YAMLs; mutations confined to `cores/<target>/rtl/*.sv` plus `cores/<target>/implementation_notes.md`.

Design (frozen here, mirrored into the prereg in Task 6):
- Per implementation slot: draw `k ~ Uniform{1,2,3}` mutations from the operator pool, apply, lint with the exact `implement.py:206-213` verilator command; on lint failure revert and redraw, up to 20 draws; if no draw lints clean, submit the last draw anyway (the gates classify it). Draw counts and lint outcomes go into `implementation_notes.md`.
- Operator pool (parse-safety over expressive power; the broader menu in `research/paper_revision_plan.md` E1 is a superset, and the prereg records this final set): `op_swap` (`+`/`-`, `&`/`|`, `==`/`!=`, with guards against `++ && || ==` composites), `ternary_swap` (single `?:` per line), `lit_perturb` (XOR 1 on sized literals `N'h.../N'd.../N'b...`).
- Determinism: `random.Random(f"{RANDOM_AGENT_SEED}:{hyp_id}")`, so a rep is reproducible given the seed and the champion state.
- Comment-only and blank lines are excluded from candidates.

- [ ] **Step 1: Write failing tests**

Create `tools/agents/test_random_agent.py`:

```python
"""Tests for the random-mutation control agent."""
import random
from pathlib import Path

from tools.agents import random_agent as ra

SV = """\
module alu(input logic [31:0] a, b, output logic [31:0] y);
  // adder path
  assign y = (a == 32'h0000_0001) ? a + b : a & b;
endmodule
"""


def _mk_worktree(tmp_path: Path) -> Path:
    rtl = tmp_path / "cores" / "bench" / "rtl"
    rtl.mkdir(parents=True)
    (rtl / "alu.sv").write_text(SV)
    return tmp_path


def test_candidates_skip_comment_lines():
    cands = ra.line_candidates("  // adder path + fast")
    assert cands == []


def test_op_swap_produces_parseable_line():
    cands = ra.line_candidates("  assign y = a + b;")
    assert any("a - b" in c.new_line for c in cands)


def test_eq_swap_guards_composites():
    cands = ra.line_candidates("  assign t = (a == b) && c;")
    assert any("!=" in c.new_line for c in cands)
    assert all("&" * 3 not in c.new_line for c in cands)


def test_ternary_swap_swaps_arms():
    line = "  assign y = sel ? a + b : a & b;"
    cands = [c for c in ra.line_candidates(line) if c.kind == "ternary_swap"]
    assert len(cands) == 1
    assert "? a & b : a + b" in cands[0].new_line


def test_lit_perturb_xors_low_bit():
    line = "  assign y = 32'h0000_0001;"
    cands = [c for c in ra.line_candidates(line) if c.kind == "lit_perturb"]
    assert len(cands) == 1
    assert "32'h0" in cands[0].new_line and "_0001" not in cands[0].new_line


def test_mutate_deterministic(tmp_path):
    wt1 = _mk_worktree(tmp_path / "a")
    wt2 = _mk_worktree(tmp_path / "b")
    rng1 = random.Random("101:hyp-x")
    rng2 = random.Random("101:hyp-x")
    m1 = ra.apply_mutations(wt1, "bench", rng1, k=2)
    m2 = ra.apply_mutations(wt2, "bench", rng2, k=2)
    assert [str(m) for m in m1] == [str(m) for m in m2]
    assert (wt1 / "cores/bench/rtl/alu.sv").read_text() == \
           (wt2 / "cores/bench/rtl/alu.sv").read_text()


def test_mutate_touches_only_rtl(tmp_path):
    wt = _mk_worktree(tmp_path)
    (wt / "Makefile").write_text("all:\n")
    before = (wt / "Makefile").read_text()
    ra.apply_mutations(wt, "bench", random.Random(1), k=3)
    assert (wt / "Makefile").read_text() == before
```

- [ ] **Step 2: Run tests, verify failure**

Run: `python3 -m pytest tools/agents/test_random_agent.py -q`
Expected: FAIL, `No module named 'tools.agents.random_agent'`.

- [ ] **Step 3: Create `tools/agents/random_agent.py`**

```python
"""Random-mutation (no-LLM) control agent.

The E1b attribution control for the v2 paper: applies seeded,
syntactically-plausible random mutations to the champion RTL and submits
them through the identical gate chain. If gated random editing improved
fitness at a rate near the LLM agents', credit for the bench results
would belong to the harness, not the agents.

Invoked exactly like static_agent (provider="random" in
_runtime.build_agent_cmd): argv[0] is the orchestrator's prompt; phase
is sniffed from prompt text.

  Hypothesis phase: writes a stub YAML at the pre-allocated id.
  Implementation phase: applies k ~ U{1,2,3} mutations drawn with
  random.Random(f"{RANDOM_AGENT_SEED}:{hyp_id or notes}") to
  cores/<target>/rtl/*.sv, lints, redraws on lint failure (max 20),
  and records every applied mutation in implementation_notes.md.

Operator pool (frozen for prereg): op_swap (+/-, &/|, ==/!=),
ternary_swap, lit_perturb. Guards keep every mutation parse-valid so
the control is not a lint-fails-instantly strawman; semantic validity
is exactly what the downstream gates measure.
"""
from __future__ import annotations

import os
import random
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

MAX_DRAWS = 20

_HYP_ID = re.compile(r"\bhyp-\d{8}-\d{3}-r\d+s\d+\b")
_TARGET = re.compile(r"cores/([\w\-]+)/")

# op_swap pairs with composite guards:
#   '+'/'-' only between word/paren/space chars (keeps ++ and unary
#   prefixes intact, and a swapped unary still parses);
#   '&'/'|' single only (never && or || or &=);
#   '=='/'!=' whole-token.
_OP_PATTERNS: list[tuple[re.Pattern, str, str]] = [
    (re.compile(r"(?<=[\w)\]\s])\+(?=[\s\w(])"), "-", "op_swap"),
    (re.compile(r"(?<=[\w)\]\s])-(?=[\s\w(])"), "+", "op_swap"),
    (re.compile(r"(?<![&|=!<>^~])&(?![&=])"), "|", "op_swap"),
    (re.compile(r"(?<![&|=!<>^~])\|(?![|=])"), "&", "op_swap"),
    (re.compile(r"(?<![=!<>])==(?!=)"), "!=", "op_swap"),
    (re.compile(r"(?<![=!<>])!=(?!=)"), "==", "op_swap"),
]
_TERNARY = re.compile(r"\?\s*([^?:;{}]+?)\s*:\s*([^;,)\n{}]+)")
_SIZED_LIT = re.compile(r"\b(\d+)'([hbdHBD])([0-9a-fA-F_]+)\b")


@dataclass
class Candidate:
    kind: str
    new_line: str


@dataclass
class Applied:
    file: str
    lineno: int
    kind: str
    before: str
    after: str

    def __str__(self) -> str:
        return (f"{self.file}:{self.lineno} [{self.kind}] "
                f"{self.before.strip()!r} -> {self.after.strip()!r}")


def line_candidates(line: str) -> list[Candidate]:
    """All single-line mutations available on `line`."""
    stripped = line.strip()
    if not stripped or stripped.startswith("//"):
        return []
    out: list[Candidate] = []
    for pat, repl, kind in _OP_PATTERNS:
        for m in pat.finditer(line):
            out.append(Candidate(
                kind, line[:m.start()] + repl + line[m.end():]))
    if line.count("?") == 1 and "::" not in line:
        m = _TERNARY.search(line)
        if m:
            swapped = (line[:m.start()]
                       + f"? {m.group(2).strip()} : {m.group(1).strip()}"
                       + line[m.end():])
            out.append(Candidate("ternary_swap", swapped))
    for m in _SIZED_LIT.finditer(line):
        width, base, digits = m.group(1), m.group(2), m.group(3)
        raw = digits.replace("_", "")
        radix = {"h": 16, "H": 16, "d": 10, "D": 10, "b": 2, "B": 2}[base]
        try:
            val = int(raw, radix) ^ 1
        except ValueError:
            continue
        fmt = {16: "x", 10: "d", 2: "b"}[radix]
        new_lit = f"{width}'{base}{val:{fmt}}"
        out.append(Candidate(
            "lit_perturb", line[:m.start()] + new_lit + line[m.end():]))
    return out


def _all_candidates(worktree: Path, target: str) -> list[tuple[Path, int, Candidate]]:
    rtl = worktree / "cores" / target / "rtl"
    cands: list[tuple[Path, int, Candidate]] = []
    for f in sorted(rtl.glob("*.sv")):
        for i, line in enumerate(f.read_text().splitlines()):
            for c in line_candidates(line):
                cands.append((f, i, c))
    return cands


def apply_mutations(worktree: Path, target: str, rng: random.Random,
                    k: int) -> list[Applied]:
    """Apply k distinct-line mutations in place. Returns what was applied."""
    cands = _all_candidates(worktree, target)
    rng.shuffle(cands)
    applied: list[Applied] = []
    used: set[tuple[Path, int]] = set()
    for f, i, c in cands:
        if len(applied) >= k:
            break
        if (f, i) in used:
            continue
        lines = f.read_text().splitlines(keepends=False)
        applied.append(Applied(str(f.relative_to(worktree)), i + 1,
                               c.kind, lines[i], c.new_line))
        lines[i] = c.new_line
        f.write_text("\n".join(lines) + "\n")
        used.add((f, i))
    return applied


def _lint_ok(worktree: Path, target: str) -> bool | None:
    """Same lint gate as implement.py. None = verilator unavailable."""
    rtl_label = f"cores/{target}/rtl"
    rtl = worktree / rtl_label
    srcs = sorted(rtl.glob("*.sv"))
    pkg = rtl / "core_pkg.sv"
    if pkg in srcs:
        srcs = [pkg, *(p for p in srcs if p != pkg)]
    if not srcs:
        return False
    try:
        r = subprocess.run(
            ["verilator", "--lint-only", "-Wall", "-Wno-MULTITOP", "-sv",
             f"+incdir+{rtl_label}",
             *(str(p.relative_to(worktree)) for p in srcs)],
            cwd=worktree, capture_output=True, timeout=300)
    except FileNotFoundError:
        return None
    return r.returncode == 0


def _git_restore_rtl(worktree: Path, target: str) -> None:
    subprocess.run(
        ["git", "checkout", "--", f"cores/{target}/rtl"],
        cwd=worktree, capture_output=True)


def _hyp_id(prompt: str) -> str | None:
    m = _HYP_ID.search(prompt)
    return m.group(0) if m else None


def _target(prompt: str) -> str:
    m = _TARGET.search(prompt)
    return m.group(1) if m else "bench"


def _write_hypothesis(prompt: str) -> None:
    target = _target(prompt)
    hyp_id = _hyp_id(prompt)
    if not hyp_id:
        print("[random-agent] no hypothesis id in prompt; skipping",
              file=sys.stderr, flush=True)
        return
    yaml_dir = Path("cores") / target / "experiments" / "hypotheses"
    yaml_dir.mkdir(parents=True, exist_ok=True)
    body = (
        f"id: {hyp_id}\n"
        f"title: \"random-mutation-control\"\n"
        "category: micro_opt\n"
        "motivation: |\n"
        "  No-LLM attribution control: this slot applies seeded random\n"
        "  syntactic mutations (tools/agents/random_agent.py) to measure\n"
        "  what the gate chain plus blind editing achieves without an LLM.\n"
        "hypothesis: |\n"
        "  Apply k ~ U{1,2,3} random parse-safe mutations to the champion\n"
        "  RTL. No semantic intent. The eval gates classify the result.\n"
        "expected_impact:\n"
        "  fitness_delta_pct: 0\n"
        "  confidence: low\n"
        "changes:\n"
        "  - file: rtl/alu.sv\n"
        "    description: |\n"
        "      Placeholder for schema minItems; actual mutated files are\n"
        "      chosen at implementation time by the seeded RNG.\n"
    )
    (yaml_dir / f"{hyp_id}.yaml").write_text(body)
    print(f"[random-agent] wrote {yaml_dir / (hyp_id + '.yaml')}", flush=True)


def _implement(prompt: str) -> None:
    target = _target(prompt)
    worktree = Path.cwd()
    seed_base = os.environ.get("RANDOM_AGENT_SEED", "0")
    hyp_id = _hyp_id(prompt) or "no-id"
    rng = random.Random(f"{seed_base}:{hyp_id}")
    k = rng.randint(1, 3)

    applied: list[Applied] = []
    lint = None
    for draw in range(1, MAX_DRAWS + 1):
        _git_restore_rtl(worktree, target)
        applied = apply_mutations(worktree, target, rng, k)
        lint = _lint_ok(worktree, target)
        if lint is not False:
            break
    notes = Path("cores") / target / "implementation_notes.md"
    notes.parent.mkdir(parents=True, exist_ok=True)
    lint_str = {True: "pass", False: "fail", None: "verilator unavailable"}[lint]
    notes.write_text(
        "Random-mutation control (no LLM). Seeded mutations applied:\n"
        + "".join(f"- {a}\n" for a in applied)
        + f"\nDraws used: {draw}/{MAX_DRAWS}; final lint: {lint_str}.\n"
        f"Seed material: {seed_base}:{hyp_id}; k={k}.\n")
    print(f"[random-agent] applied {len(applied)} mutation(s), "
          f"draw {draw}, lint {lint_str}", flush=True)


def main(argv: list[str] | None = None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    if not argv:
        print("[random-agent] no prompt; nothing to do", file=sys.stderr)
        return 0
    prompt = argv[0]
    if "## Hypothesis schema" in prompt or "hypothesis YAML" in prompt:
        _write_hypothesis(prompt)
    elif ("Edit, create, or delete files in the worktree" in prompt
          or "implementation_notes.md" in prompt):
        _implement(prompt)
    else:
        print(f"[random-agent] unrecognized prompt; first 80 chars: "
              f"{prompt[:80]!r}", file=sys.stderr, flush=True)
    if "--output-last-message" in argv:
        i = argv.index("--output-last-message")
        if i + 1 < len(argv):
            try:
                Path(argv[i + 1]).write_text("random-agent: done\n")
            except OSError:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run tests, verify pass**

Run: `python3 -m pytest tools/agents/test_random_agent.py -q`
Expected: 7 passed. If `test_lit_perturb_xors_low_bit` fails on
formatting, the expected output for `32'h0000_0001` is `32'h0` (XOR 1 of
1 is 0; underscores are not preserved). Adjust nothing else.

- [ ] **Step 5: Register the provider**

In `tools/agents/_runtime.py`:

(a) ~line 39:

```python
VALID_PROVIDERS = ("codex", "claude", "opencode", "static", "random")
```

(b) In `build_agent_cmd`, after the `static` branch (~line 325), add:

```python
    if p == "random":
        # Seeded random-mutation control (E1b). Same invocation contract
        # as static; RANDOM_AGENT_SEED env drives determinism.
        cmd = [sys.executable, "-B", "-m", "tools.agents.random_agent", prompt]
        if output_last_message is not None:
            cmd += ["--output-last-message", str(output_last_message)]
        return cmd
```

(c) In `tools/bench/runner.py` `make_env_for_job`, after the `static`
branch (~line 444):

```python
    elif job.model.provider == "random":
        # Seeded mutation control. Seed = 100 + rep, so reps 1..3 map to
        # the preregistered seeds 101..103 and reruns are reproducible.
        env["AGENT_PROVIDER"] = "random"
        env["RANDOM_AGENT_SEED"] = str(100 + job.rep)
```

and extend the error message in the final `else` to include `random`.

- [ ] **Step 6: Create `tools/bench/models-random.yaml`**

```yaml
# E1b attribution control: seeded random mutations, no LLM.
# Seeds are 100 + rep (runner.make_env_for_job), so --reps 3 gives the
# preregistered seed list [101, 102, 103].
# Run (scratch results while validating; real E1 run drops the overrides):
#   python -m tools.bench.runner --models tools/bench/models-random.yaml \
#     --reps 3 --n 15 --k 3 --ref bench-v2
models:
  - name: random-mutation
    provider: random
    model: mutation-v1
```

- [ ] **Step 7: Full suite + smoke + commit**

Run: `python3 -m pytest tools/ -q` -> all pass.
Run: `python3 -m tools.bench.runner --dry-run --models tools/bench/models-random.yaml --reps 3`
Expected: 3 jobs queued, `random:mutation-v1` each.

```bash
git add tools/agents/random_agent.py tools/agents/test_random_agent.py \
  tools/agents/_runtime.py tools/bench/runner.py tools/bench/models-random.yaml
git commit -m "tools: add seeded random-mutation control agent (E1b)"
```

---

### Task 5: Naive-LLM prompt profile (E1c) + sandbox scratch guidance

**Files:**
- Modify: `tools/bench/runner.py` (ModelEntry ~line 61, load_models ~line 98, make_env_for_job ~line 422)
- Modify: `tools/agents/hypothesis.py` (prompt builder, `_build_prompt` at ~line 172; read lines 172-315 first)
- Modify: `tools/agents/implement.py` (`_build_prompt`, lines 12-140)
- Create: `tools/bench/models-naive.yaml`
- Test: extend `tools/agents/test_hypothesis.py`

**Interfaces:**
- Produces: `BENCH_PROMPT_PROFILE` env contract: unset/`full` = current behavior, `naive` = stripped prompts; `ModelEntry.prompt_profile: str = "full"` and YAML key `prompt_profile`.

The naive profile keeps ONLY what mechanical validity requires (pre-allocated id, YAML schema block, write fence, port-contract pointer, inline RTL dump for cost parity) and drops all optimization scaffolding (lesson log, recent outcomes, current/baseline fitness, targets clause, ARCHITECTURE.md, CORE_PHILOSOPHY.md). It measures the raw LLM prior at equal token budget.

- [ ] **Step 1: Read the hypothesis prompt builder**

Read `tools/agents/hypothesis.py` lines 129-320 (`_recent_outcomes`,
`_lessons_block`, `_targets_clause`, `_build_prompt`). Identify: (a) the
parameter carrying the pre-allocated hyp id and slot category, (b) where
the schema block (`## Hypothesis schema`) is embedded. The naive prompt
must retain both (a) and (b) verbatim; static_agent and random_agent key
off `## Hypothesis schema`, and the orchestrator's whitelist keys off the
pre-allocated id.

- [ ] **Step 2: Write failing test**

Append to `tools/agents/test_hypothesis.py` (match its existing import
style after reading its first 30 lines):

```python
def test_naive_profile_strips_scaffold(monkeypatch):
    monkeypatch.setenv("BENCH_PROMPT_PROFILE", "naive")
    prompt = _build_prompt_for_test()   # reuse the file's existing helper
                                        # or minimal-args call to _build_prompt
    assert "## Hypothesis schema" in prompt
    assert "hyp-" in prompt
    for banned in ("Lessons", "Recent outcomes", "current fitness",
                   "baseline fitness", "Targets"):
        assert banned.lower() not in prompt.lower()


def test_full_profile_unchanged(monkeypatch):
    monkeypatch.delenv("BENCH_PROMPT_PROFILE", raising=False)
    prompt = _build_prompt_for_test()
    assert "## Hypothesis schema" in prompt
```

If the test file has no prompt-builder helper, write
`_build_prompt_for_test()` in the test module calling `_build_prompt`
with the minimal fixture args its signature requires (visible from
Step 1; use empty log tail, fitness 282.82, one pre-allocated id
`hyp-20260101-001-r1s0`).

- [ ] **Step 3: Implement the naive branch in hypothesis.py**

At the top of `_build_prompt`, add:

```python
    naive = os.environ.get("BENCH_PROMPT_PROFILE", "full") == "naive"
```

Where the full prompt assembles lessons/outcomes/targets/fitness
sections, gate each with `"" if naive else <section>`. Do NOT fork the
whole template; suppress sections in place so the id, schema block,
fence text, and file-path instructions stay identical between profiles.

- [ ] **Step 4: Implement the naive branch in implement.py**

In `_build_prompt` (`tools/agents/implement.py:12`):

```python
    naive = os.environ.get("BENCH_PROMPT_PROFILE", "full") == "naive"
```

Gate the two knowledge sections:

```python
    arch_section = "" if naive else f"## Architecture\n{arch}\n\n"
```

(and use `arch_section` in the f-string where `## Architecture` is now),
and wrap the existing `philosophy` computation with `if not naive:`.
Add `import os` to the module imports.

Additionally (both profiles), append one line to instruction 4's formal
guidance, motivated by the sol rep2 log (codex sandbox rejected
`/private/tmp` staging):

```
   Stage any scratch copies under $TMPDIR or ./.tmp inside the
   workspace; the sandbox rejects writes to /tmp or /private/tmp.
```

- [ ] **Step 5: Plumb prompt_profile through the runner**

In `tools/bench/runner.py`:

(a) `ModelEntry` dataclass, add field:

```python
    # Prompt profile: "full" (default) or "naive" (E1c control: strips
    # lesson log, outcomes, metrics, and architecture docs from prompts).
    prompt_profile: str = "full"
```

(b) `load_models`, add to the constructor call:

```python
            prompt_profile=m.get("prompt_profile", "full") or "full",
```

(c) `make_env_for_job`, after the provider branches:

```python
    if job.model.prompt_profile != "full":
        env["BENCH_PROMPT_PROFILE"] = job.model.prompt_profile
```

- [ ] **Step 6: Create `tools/bench/models-naive.yaml`**

Copy the `gpt-5_5_medium` entry verbatim from
`tools/bench/models-gpt55-effort.yaml` (verify exact `model`, `variant`,
`oauth`, `provider` fields), rename it, and add the profile key:

```yaml
# E1c attribution control: same model/runtime/budget as gpt-5_5_medium,
# prompt stripped to mechanical requirements only (no lesson log, no
# outcomes, no metrics, no architecture docs). Isolates the scaffold's
# contribution from the raw LLM prior.
models:
  - name: naive-gpt-5_5_medium
    provider: opencode          # verify against models-gpt55-effort.yaml
    model: openai/gpt-5.5       # verify
    variant: medium             # verify
    oauth: true                 # verify
    prompt_profile: naive
```

- [ ] **Step 7: Tests + commit**

Run: `python3 -m pytest tools/ -q` -> all pass.

```bash
git add tools/agents/hypothesis.py tools/agents/implement.py \
  tools/agents/test_hypothesis.py tools/bench/runner.py tools/bench/models-naive.yaml
git commit -m "tools: naive prompt profile (E1c control) + in-workspace scratch guidance"
```

---

### Task 6: Prereg files, burn-in gate, dual-lane check

**Files:**
- Create: `research/runs/EXP-2026-07-e1a-static-control/prereg.yaml`
- Create: `research/runs/EXP-2026-07-e1b-random-control/prereg.yaml`
- Create: `research/runs/EXP-2026-07-e1c-naive-control/prereg.yaml`
- Modify: `tools/bench/lite.yaml` (stale schema refresh)
- No source changes; this task executes and records.

**Interfaces:**
- Consumes: everything above.
- Produces: the burn-in verdict that unblocks tracker Task #4 (compute matrix), plus frozen preregs for the E1 arms.

- [ ] **Step 1: Refresh the stale lite config**

`tools/bench/lite.yaml` references a removed `pi_model` schema and a
`--config` flag that does not exist. Replace its `models:` block with
the current schema (keep the explanatory header comments, updating the
invocation line to `python -m tools.bench.runner --models tools/bench/lite.yaml --reps 1 --n 5 --k 1`):

```yaml
models:
  - name: lite-gpt-5_5_medium
    provider: opencode
    model: openai/gpt-5.5     # verify against models-gpt55-effort.yaml
    variant: medium
    oauth: true
```

Note: `N: 5`, `K: 1`, `reps: 1`, `seeds_per_pnr: 1` keys at the top are
documentation only (runner ignores them); leave them but add a comment
saying so.

- [ ] **Step 2: Write the three prereg files**

`research/runs/EXP-2026-07-e1b-random-control/prereg.yaml` (WRITE-ONCE
after this commit; amendments require a dated amendment block):

```yaml
run_id: EXP-2026-07-e1b-random-control
question: >
  Do blind syntactic mutations through the identical gate chain produce
  accepted fitness improvements at a rate comparable to LLM agents?
hypothesis: >
  Random mutation accepts ~0 strict improvements per 46-row rep; any
  accepted cumulative delta is < 5%.
baseline_run_id: paper-snapshot-17rep (bench/results.jsonl status=done)
primary_metric: final champion fitness (iter/s) per rep
secondary_metrics: [accepted_count, gate_pass_rate, first_failing_gate_distribution, lint_draws_used]
operator_set: [op_swap(+/-, "&/|", ==/!=), ternary_swap, lit_perturb]
mutation_policy: k~U{1,2,3} per slot; lint-guided redraw, max 20 draws; submit last draw if none lint
seeds: [101, 102, 103]   # RANDOM_AGENT_SEED = 100 + rep
config: {n: 15, k: 3, reps: 3, ref: bench-v2}
success_rule: >
  "Agent editing beats gated random sampling" is claimed iff every LLM
  config mean exceeds the E1b mean with non-overlapping 95% bootstrap
  CIs AND E1b mean accepted-count < 1. If E1b acceptance is materially
  nonzero, reframe per W4 (gated-search benchmark), no goalpost move.
note: >
  Operator set is narrower than the superset menu in
  research/paper_revision_plan.md E1 (parse-safe subset); recorded here
  before any run, so this is a pre-launch refinement, not an amendment.
```

`...e1a-static-control/prereg.yaml`:

```yaml
run_id: EXP-2026-07-e1a-static-control
question: What does the harness measure when the agent does nothing?
hypothesis: delta_pct = 0.0 exactly (pinned P&R seeds); 46 rows, 1 accepted (baseline retest), 45 regressions.
baseline_run_id: paper-snapshot-17rep
primary_metric: final champion fitness per rep
seeds: [n/a — deterministic]
config: {n: 15, k: 3, reps: 1, ref: bench-v2}
success_rule: any nonzero delta or broken row = harness bug; block all E1/E2 runs until explained.
```

`...e1c-naive-control/prereg.yaml`:

```yaml
run_id: EXP-2026-07-e1c-naive-control
question: >
  How much of gpt-5_5_medium's measured gain survives when the scaffold
  (lesson log, outcomes, metrics, architecture docs) is stripped?
hypothesis: >
  Naive mean final fitness lands between E1b (random) and full-scaffold
  gpt-5_5_medium (423.5 +/- 11.2, n=3).
baseline_run_id: gpt-5_5_medium reps 1-3 (results.jsonl)
primary_metric: final champion fitness per rep
seeds: [provider sampling; reps 1-3]
config: {n: 15, k: 3, reps: 3, ref: bench-v2, prompt_profile: naive}
success_rule: >
  Scaffold contribution is claimed iff full-scaffold mean exceeds naive
  mean with non-overlapping 95% bootstrap CIs at n=3+3; otherwise
  reported as "not separated at this n".
```

- [ ] **Step 3: Commit preregs and lite refresh**

```bash
git add research/runs tools/bench/lite.yaml
git commit -m "research: preregister E1 control arms; refresh stale lite.yaml schema"
```

- [ ] **Step 4: Burn-in run A, static pair, parallel (concurrency + noise floor)**

```bash
mkdir -p /tmp/bench-burnin
python3 -m tools.bench.runner --models tools/bench/models-static.yaml \
  --reps 2 --parallel 2 --n 1 --k 1 --ref bench-v2 \
  --results-jsonl /tmp/bench-burnin/results.jsonl \
  --results-dir /tmp/bench-burnin --clone-base /tmp/bench-burnin/clones \
  --keep-clones
```

Expected: preflight block prints; both reps `status=done`, `delta_pct=0.0`,
`orchestrator.log` and `env.json` present in `/tmp/bench-burnin/static/rep{1,2}/`.
This also reproduces the sol launch pattern (two reps starting the same
second). Record wall-clock of each rep; then rerun with `--parallel 1`
and compare per-rep eval time to quantify dual-lane CPU contention.
Record both numbers in `research/diary/2026-07-DD.md`.

- [ ] **Step 5: Burn-in run B, back-to-back invocations (sol first-failure pattern)**

```bash
python3 -m tools.bench.runner --models tools/bench/models-static.yaml \
  --reps 3 --n 1 --k 1 --ref bench-v2 \
  --results-jsonl /tmp/bench-burnin/results.jsonl \
  --results-dir /tmp/bench-burnin --clone-base /tmp/bench-burnin/clones \
&& python3 -m tools.bench.runner --models tools/bench/models-random.yaml \
  --reps 1 --n 2 --k 3 --ref bench-v2 \
  --results-jsonl /tmp/bench-burnin/results.jsonl \
  --results-dir /tmp/bench-burnin --clone-base /tmp/bench-burnin/clones
```

Expected: static rep3 skipped-or-done cleanly (resume logic), random rep
completes end-to-end with mutations recorded in its rep dir log, most
slots broken or rejected (that is the point of the control). Verify the
random rep's `log.jsonl` rows carry real first-failing-gate classes.

- [ ] **Step 6: Burn-in runs C and D, one lite rep per runtime**

```bash
python3 -m tools.bench.runner --models tools/bench/lite.yaml \
  --reps 1 --n 2 --k 1 --ref bench-v2 \
  --results-jsonl /tmp/bench-burnin/results.jsonl \
  --results-dir /tmp/bench-burnin --clone-base /tmp/bench-burnin/clones
```

then the same with a codex-runtime entry (create a one-off scratch YAML
copying the `gpt-5_5_xhigh` codex-side identity from
`tools/bench/models-gpt55-effort.yaml` if that file routes via opencode;
otherwise reuse an existing codex-provider YAML entry with `--only`).
Expected: both reps `status=done` with at least one gate-passing row
each; no `hypothesis_gen_failed` storms; token counts nonzero in the
results rows (parity check that both runtimes report usage).

- [ ] **Step 7: Verify disk behavior (requires Task 7 landed first)**

After the Step 4 static pair, measure:

```bash
du -sh /tmp/bench-burnin/clones/* ; du -sh formal/riscv-formal
```

Expected: each live clone well under 1.5 GB (CoW copy means riscv-formal
contributes ~0 real blocks; `du` may still report apparent size, so also
check `df -h /System/Volumes/Data` free-space delta across the run, which
must be < 2 GB per rep); the main repo's `formal/riscv-formal` unchanged;
after runner exit with default flags, `/tmp/bench-burnin/clones/` empty
(clones removed) while each rep dir retains `orchestrator.log`, `env.json`,
`log.jsonl`, and `repo.bundle`.

- [ ] **Step 8: Record the burn-in verdict**

Append to `research/diary/2026-07-DD.md` (create if missing): commands,
results (all `value +/- dispersion` where applicable, n stated), the
dual-lane contention number from Step 4, the disk numbers from Step 7,
and the explicit verdict "burn-in gate PASSED/FAILED". Update tracker
Task #1 and #2 to completed only on PASS; on FAIL, file the failure as
an INCIDENT entry and stop (do not proceed to the compute matrix).

---

### Task 7: Disk hygiene (execute BEFORE Task 6's burn-in runs)

**Files:**
- Modify: `tools/bench/runner.py` (`clone_fixture` ~line 359-367, `run_one_job` finalize ~line 984-990)
- Modify: `tools/eval/formal.py` (post-tally workdir cleanup)
- Modify: `tools/bench/preflight.py` (free-disk check)
- Create: `tools/bench/gc.py` (stale-run sweeper)
- Tests: `tools/bench/test_preflight.py`, `tools/eval/` test conventions, `tools/bench/test_gc.py`

**Interfaces:**
- Consumes: `preflight.REQUIRED_TOOLS` etc. from Task 2/3.
- Produces: per-rep disk residue of a few hundred MB instead of ~6 GB; `bench/<model>/rep<N>/repo.bundle` (full git history of the rep, replaces keep-clones for forensics); `python -m tools.bench.gc` sweeper; preflight refuses to start with < 30 GB free.

Measured baseline (2026-07-15, 4 surviving clones): 6.1-6.3 GB per rep
clone, of which `formal/riscv-formal` is 5.4 GB (the main repo's vendored
checkout carries years of stale SBY work dirs and is copied whole per
clone with `cp -R`), `cores/bench/worktrees` 394 MB, `cores/bench/generated`
114 MB. Upstream riscv-formal alone is ~50 MB. 48 planned reps at this
rate is ~300 GB, which is what the author hit.

- [ ] **Step 1: Prune the main repo's riscv-formal work-dir garbage**

`formal/riscv-formal` is a git checkout; anything untracked under
`cores/` is our run garbage or our local check configs. Discriminate:

```bash
cd formal/riscv-formal
git status --porcelain cores/ | head -40   # untracked = not upstream
grep -rhoE "cores/[a-zA-Z0-9_-]+" ../run_all.sh ../../Makefile | sort -u
```

Delete only: (a) PID-suffixed work dirs matching `cores/*-[0-9]*` (e.g.
`bench-44577`, `baseline-75670`), and (b) untracked dirs NOT referenced by
`run_all.sh`, the Makefile, or docs (`auto-arch-researcher`,
`codex-*-maxperf`, `maxperf`, `mini` are expected junk; `bench`,
`baseline`, `v1` are likely OUR genchecks configs and must survive if
referenced). Record `du -sh formal/riscv-formal` before and after in the
report. Expected after: well under 1 GB.

- [ ] **Step 2: Copy-on-write clone of riscv-formal (APFS), with exclusions**

In `clone_fixture` (~line 359), replace the `cp -R` with a darwin
clonefile fast path plus work-dir exclusion, and update the stale
"~200 MB" comment (measured: 5.4 GB before Step 1):

```python
    rf_src = find_riscv_formal()
    if rf_src is not None:
        rf_dest = dest / "formal" / "riscv-formal"
        rf_dest.parent.mkdir(parents=True, exist_ok=True)
        if not rf_dest.exists():
            # APFS clonefile (cp -c) is copy-on-write: ~zero extra disk
            # and ~instant. Fall back to plain cp -R off-macOS.
            cp_cow = subprocess.run(
                ["cp", "-Rc", str(rf_src.resolve()), str(rf_dest)],
                capture_output=True)
            if cp_cow.returncode != 0:
                subprocess.run(
                    ["cp", "-R", str(rf_src.resolve()), str(rf_dest)],
                    check=True)
            # Never inherit prior runs' SBY work dirs into a fresh rep.
            for junk in rf_dest.glob("cores/*-[0-9]*"):
                shutil.rmtree(junk, ignore_errors=True)
```

- [ ] **Step 3: Per-iteration SBY workdir cleanup in tools/eval/formal.py**

Read `tools/eval/formal.py` and `formal/run_all.sh` (READ ONLY, it is
contract) to find how the run's `cores/<core>-<PID>` workdir is named.
After the tally is parsed and the failing-check log tail captured, add
a cleanup that removes that workdir (successful and failed runs both;
the captured tail and `last_run-<PID>.log` stay). Guard with env
`BENCH_KEEP_FORMAL_WORKDIR=1` for debugging. Add a unit test following
the existing `tools/eval/test_formal_*.py` conventions (fake workdir,
assert removed / kept under the env flag).

- [ ] **Step 4: End-of-rep bundle + always-clean clones**

In `run_one_job` finalize, before the clone removal (~line 988), bundle
the rep's full git history (accepted diffs, log commits) into the rep
dir so `--keep-clones` is no longer needed for forensics:

```python
    bundle = subprocess.run(
        ["git", "bundle", "create", str(out_dir / "repo.bundle"), "--all"],
        cwd=str(clone), capture_output=True)
    if bundle.returncode != 0:
        print(f"  [bench] warn: git bundle failed: "
              f"{bundle.stderr.decode()[:200]}", flush=True)
```

Keep the `--keep-clones` flag semantics (debugging), but the default
path now preserves everything that matters and removes the clone.

- [ ] **Step 5: Disk preflight**

Add to `tools/bench/preflight.py`:

```python
MIN_FREE_GB = 30


def free_disk_gb(path: str = ".") -> float:
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize / 1e9
```

and a check in `report()`/runner main: if `free_disk_gb() < MIN_FREE_GB`,
FATAL with the measured number (same style as missing tools; also honors
`--skip-preflight`). Unit test with monkeypatched `os.statvfs`.

- [ ] **Step 6: Stale-run sweeper**

Create `tools/bench/gc.py`:

```python
"""Sweep stale bench-run clones and formal work dirs.

Usage:
    python -m tools.bench.gc            # dry-run: list + sizes
    python -m tools.bench.gc --delete   # actually remove
"""
```

Targets: `.claude/bench-runs/*` whose `(model, rep)` already has a rep
dir under `bench/` (archive `.tmp/orchestrator.log` + `.tmp/env.json`
into that rep dir first if absent, and create `repo.bundle` there if
absent), and `formal/riscv-formal/cores/*-[0-9]*` in the main repo.
Dry-run by default, `--delete` to act, prints per-target sizes and the
total reclaimed. Unit test with a fabricated directory tree.

- [ ] **Step 7: Reclaim the current 25 GB**

Run `python -m tools.bench.gc` (dry-run), verify the list is exactly the
4 surviving sol/terra clones plus main-repo formal junk, then run with
`--delete`. Record before/after `df -h` in the report. The four clones'
orchestrator.log/env.json must exist in their `bench/gpt-5_6-*/rep*/`
dirs before deletion (the sweeper archives them; verify).

- [ ] **Step 8: Full suite + commit**

Run: `python3 -m pytest tools/ -q` -> all pass.

```bash
git add tools/bench/runner.py tools/eval/formal.py tools/bench/preflight.py \
  tools/bench/gc.py tools/bench/test_gc.py tools/bench/test_preflight.py
git commit -m "tools: disk hygiene (CoW riscv-formal, SBY cleanup, rep bundles, gc sweeper, disk preflight)"
```

---

## Self-review notes

- Spec coverage: tracker Task #1 (forensics, preflight, pyc, dual-lane check, burn-in gate) = plan Tasks 1, 2, 3, 6; tracker Task #2 (random + naive agents + preregs) = plan Tasks 4, 5, 6. The codex-parity audit item from the tracker is partially covered (Step 6 of Task 6 checks token parity and clean runs; the sandbox-scratch prompt line lands in Task 5); a fuller prompt-parity diff between runtimes is deferred to the compute-matrix task where the runtime arm is defined.
- Sol root cause: first-attempt exit-1 remains unproven (evidence destroyed); this plan makes recurrence diagnosable in one look (preflight + preserved orchestrator.log + env.json) and reproduces both launch patterns in burn-in. That satisfies diagnose-before-fix without inventing a cause.
- Type consistency: `preflight.env_fingerprint/missing_tools/report` used in Tasks 2-3 as defined; `Candidate.kind/new_line` and `apply_mutations(worktree, target, rng, k)` match between tests and implementation; `prompt_profile` field name identical across dataclass, YAML, and env plumbing.
- Known judgment calls (flag to reviewer): (a) random agent submits its last draw even if lint fails after 20 draws, keeping the control honest about lint-failure rates; (b) naive profile keeps the inline RTL dump for token-cost parity; (c) `models-naive.yaml` and lite.yaml carry "verify" comments because the exact gpt-5_5_medium identity strings must be copied from `models-gpt55-effort.yaml` at execution time.
