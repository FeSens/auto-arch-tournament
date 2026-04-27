"""Invokes claude -p in the worktree to implement a hypothesis."""
import subprocess, yaml
from pathlib import Path

def _build_prompt(hypothesis: dict, worktree: str) -> str:
    arch = Path(worktree, "ARCHITECTURE.md").read_text()
    claude_md_path = Path(worktree, "CLAUDE.md")
    claude_md = claude_md_path.read_text() if claude_md_path.exists() else ""
    src_files = sorted(Path(worktree, "rtl").rglob("*.sv"))
    src_dump  = "\n\n".join(
        f"=== {f.relative_to(worktree)} ===\n{f.read_text()}"
        for f in src_files
    )

    changes_str = "\n".join(
        f"  - {c['file']}: {c['description']}"
        for c in hypothesis.get('changes', [])
    )

    return f"""You are a CPU RTL implementation agent.

Your job: implement the following architectural hypothesis in SystemVerilog.

## Hypothesis
Title: {hypothesis['title']}
Category: {hypothesis['category']}

Motivation:
{hypothesis['motivation']}

Proposed change:
{hypothesis['hypothesis']}

Advisory file changes (you may deviate, add, rename, or restructure freely):
{changes_str}

## Architecture
{arch}

## Hard invariants and don't-touch list
{claude_md}

## Current SystemVerilog Source (your working directory)
{src_dump}

## Instructions
1. Implement the hypothesis by editing, creating, or restructuring files in rtl/.
   You may create new files, delete files, merge files, or split files.
2. The top module MUST stay named `core` and expose the io_* RVFI port set.
   Do NOT modify anything in tools/, schemas/, formal/, fpga/, test/cosim/,
   bench/, ARCHITECTURE.md, CLAUDE.md, README.md, setup.sh, or Makefile.
3. After implementing, verify the build:
     verilator --lint-only -Wall -Wno-MULTITOP -sv rtl/*.sv
   Fix any errors / warnings before finishing.
4. Write implementation_notes.md in the current directory describing:
   - What you actually changed (vs. the hypothesis plan)
   - Any deviations and why
   - Any concerns about the implementation

Use your Edit, Write, Read, and Bash tools freely."""


def run_implementation_agent(hypothesis_path: str, worktree: str) -> bool:
    """
    Invokes claude -p in the worktree to implement the hypothesis.
    Returns True if the post-implementation verilator lint succeeds.
    """
    with open(hypothesis_path) as f:
        hypothesis = yaml.safe_load(f)

    prompt = _build_prompt(hypothesis, worktree)

    subprocess.run(
        ["claude", "-p", prompt, "--dangerously-skip-permissions"],
        cwd=worktree,
        timeout=600,
    )

    # Lint as the smoke gate. Subsequent eval gates (formal, cosim, fpga)
    # exercise actual behavior; this catches the most basic SV breakage.
    lint_cmd = ("if ls rtl/*.sv >/dev/null 2>&1; then "
                "verilator --lint-only -Wall -Wno-MULTITOP -sv rtl/*.sv; "
                "else echo 'lint: no source files in rtl/'; exit 1; fi")
    lint = subprocess.run(
        ["bash", "-lc", lint_cmd],
        cwd=worktree, capture_output=True,
    )
    return lint.returncode == 0
