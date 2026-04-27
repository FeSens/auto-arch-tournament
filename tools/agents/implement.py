"""Invokes claude -p in the worktree to implement a hypothesis."""
import json, subprocess, threading, yaml
from pathlib import Path

CLAUDE_TIMEOUT_SEC = 600*3  # 10 min watchdog on the implementation agent

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
4. Self-check formal locally before declaring done:
     bash formal/run_all.sh
   This is the same gate the orchestrator runs in Phase 4. Catching
   easy mistakes here (broken decoder arm, missed forwarding case,
   missing default in a case statement) saves an entire iteration
   getting marked broken on a one-line fix.

   On failure, run_all.sh prints the failing check's logfile.txt tail
   to stdout — last 30 lines, which contains the SMT counterexample
   from sby. Read it, identify the bug class, fix rtl/, re-run.

   CAP: 2 fix attempts. If formal still fails after 2 retries, STOP.
   Document what you tried and what's still broken in
   implementation_notes.md and exit. Do not fight a stubborn check —
   some hypotheses are genuinely wrong and the orchestrator's hard
   gate is the right place to record that, not your watchdog budget.

   A passing local formal does NOT mean the hypothesis is accepted.
   The orchestrator still runs cosim (RVFI byte-exact vs Python ISS)
   and FPGA fitness (3-seed nextpnr median Fmax × CoreMark IPC) after
   you finish; passing formal locally just means you didn't ship an
   obvious bug.
5. Write implementation_notes.md in the current directory describing:
   - What you actually changed (vs. the hypothesis plan)
   - Any deviations and why
   - Any concerns about the implementation
   - Local formal status (pass / fail-after-N-attempts) and, if it
     failed, what counterexample you saw and what you tried.

Use your Edit, Write, Read, and Bash tools freely."""


def _summarize_event(line: str) -> str | None:
    """Best-effort one-liner from a stream-json NDJSON event.

    Returns a human-readable summary for tool_use events; None for events
    we don't want to echo to the orchestrator's terminal (text deltas,
    system messages, etc.). Failures here MUST NOT raise — the .claude.log
    file is the authoritative record.
    """
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        return None
    if ev.get('type') != 'assistant':
        return None
    for c in ev.get('message', {}).get('content', []) or []:
        if not isinstance(c, dict):
            continue
        if c.get('type') == 'tool_use':
            inp = c.get('input') or {}
            target = (inp.get('file_path')
                      or inp.get('command')
                      or inp.get('description')
                      or inp.get('pattern')
                      or '')
            if isinstance(target, str) and len(target) > 80:
                target = target[:77] + '...'
            return f"{c.get('name', '?')}: {target}".rstrip(': ').strip()
    return None


def _run_claude_streaming(cmd: list, cwd: str, log_path: Path,
                          timeout_sec: int) -> tuple[int, bool]:
    """Run claude -p with NDJSON streaming, watchdog, and one-line summaries.

    Returns (returncode, timed_out). Caller decides retry/fail.

    Duplicated across tools/agents/hypothesis.py and tools/agents/implement.py
    so neither module imports a private symbol from the other (same rationale
    as the existing _summarize_event duplication).
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


def run_implementation_agent(hypothesis_path: str, worktree: str) -> bool:
    """
    Invokes claude -p in the worktree to implement the hypothesis.

    Streams claude's output to <worktree>/.claude.log so phase 2 progress
    is observable via `tail -f` from another terminal. The default
    `claude -p` (text mode) buffers everything until the final response,
    which makes a 5-15 minute architectural-change agent look frozen.
    --output-format stream-json emits NDJSON tool-use events as they
    happen, so each Edit/Write/Bash lands in the log within ~1 second
    of the model dispatching it.

    A best-effort one-liner per tool_use is also echoed to the
    orchestrator's terminal — if claude changes the event shape, that
    echo silently degrades but the raw NDJSON in .claude.log stays
    authoritative.

    Returns True if the post-implementation verilator lint succeeds.
    """
    with open(hypothesis_path) as f:
        hypothesis = yaml.safe_load(f)

    prompt = _build_prompt(hypothesis, worktree)
    log_path = Path(worktree) / ".claude.log"

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
