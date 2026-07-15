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
is exactly what the downstream gates measure. If verilator is not on
PATH at implementation time, the agent applies NO mutations and marks
the slot INVALID in implementation_notes.md, so the final RTL for a
given seed never depends on toolchain availability.
"""
from __future__ import annotations

import os
import random
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

MAX_DRAWS = 20

_HYP_ID = re.compile(r"\bhyp-\d{8}-\d{3}-r\d+s\d+\b")
_TARGET = re.compile(r"cores/([\w\-]+)/")
_ID_MARKER = "Use exactly this hypothesis ID:"

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
    # Prefer the authoritative id clause hypothesis.py emits ("Use exactly
    # this hypothesis ID: <id>"). Round >= 2 prompts also quote prior
    # rounds' ids in the history section, which sits BEFORE this clause,
    # so a plain leftmost search grabs the wrong (stale) id. Only fall
    # back to leftmost search for older prompt shapes without the marker.
    marker_idx = prompt.find(_ID_MARKER)
    if marker_idx != -1:
        m = _HYP_ID.search(prompt, marker_idx + len(_ID_MARKER))
        if m:
            return m.group(0)
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

    # Determinism guard: without verilator the redraw loop cannot run,
    # and submitting an unguided draw would make the final RTL for a
    # given seed depend on toolchain availability. Refuse loudly and
    # leave the RTL unchanged instead (the slot evaluates as a no-op,
    # same as the static control). The runner preflight makes this
    # unreachable in production runs.
    if shutil.which("verilator") is None:
        _git_restore_rtl(worktree, target)
        notes = Path("cores") / target / "implementation_notes.md"
        notes.parent.mkdir(parents=True, exist_ok=True)
        notes.write_text(
            "Random-mutation control INVALID for this slot: verilator "
            "unavailable, no mutations applied.\n"
            f"Seed material: {seed_base}:{hyp_id}; k={k}.\n")
        print("[random-agent] ERROR: verilator not on PATH; refusing to "
              "mutate (slot marked INVALID)", file=sys.stderr, flush=True)
        return

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
