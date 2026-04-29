"""Invokes the active agent runtime (codex by default; claude opt-in via
AGENT_PROVIDER) in the worktree to implement a hypothesis."""
import subprocess, yaml
from pathlib import Path
from tools.agents._runtime import (
    build_agent_cmd,
    run_agent_streaming,
)

CLAUDE_TIMEOUT_SEC = 600*3  # 10 min watchdog on the implementation agent

def _build_prompt(hypothesis: dict, worktree: str,
                  target: str | None = None) -> str:
    arch = Path(worktree, "ARCHITECTURE.md").read_text()
    claude_md_path = Path(worktree, "CLAUDE.md")
    claude_md = claude_md_path.read_text() if claude_md_path.exists() else ""
    rtl_dir = Path(worktree, "cores", target, "rtl") if target else Path(worktree, "rtl")
    rtl_rel = str(rtl_dir.relative_to(worktree))
    src_files = sorted(rtl_dir.rglob("*.sv"))
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
1. Implement the hypothesis by editing, creating, or restructuring files in {rtl_rel}/.
   You may create new files, delete files, merge files, or split files.
2. The top module MUST stay named `core` and expose the io_* RVFI port set.
   Do NOT modify anything in tools/, schemas/, formal/, fpga/, test/cosim/,
   bench/, ARCHITECTURE.md, CLAUDE.md, README.md, setup.sh, or Makefile.
3. After implementing, verify the build:
     verilator --lint-only -Wall -Wno-MULTITOP -sv {rtl_rel}/*.sv
   Fix any errors / warnings before finishing.
4. Self-check formal locally before declaring done:
     bash formal/run_all.sh
   This is the same gate the orchestrator runs in Phase 4. Catching
   easy mistakes here (broken decoder arm, missed forwarding case,
   missing default in a case statement) saves an entire iteration
   getting marked broken on a one-line fix.

   On failure, run_all.sh prints the failing check's logfile.txt tail
   to stdout — last 30 lines, which contains the SMT counterexample
   from sby. Read it, identify the bug class, fix {rtl_rel}/, re-run.

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

Edit, create, or delete files in the worktree as needed. The eval gates
will check the result; do not output any other narrative."""


def run_implementation_agent(hypothesis_path: str, worktree: str,
                             target: str | None = None) -> bool:
    """
    Invokes the active agent runtime in the worktree to implement the hypothesis.

    Streams agent output to <worktree>/.agent.log so phase 2 progress
    is observable via `tail -f` from another terminal. The default
    `claude -p` (text mode) buffers everything until the final response,
    which makes a 5-15 minute architectural-change agent look frozen.
    --output-format stream-json emits NDJSON tool-use events as they
    happen, so each Edit/Write/Bash lands in the log within ~1 second
    of the model dispatching it. Codex streams its output similarly.

    A best-effort one-liner per tool_use is also echoed to the
    orchestrator's terminal — if the provider changes the event shape,
    that echo silently degrades but the raw log in .agent.log stays
    authoritative.

    Args:
      hypothesis_path — path to the hypothesis YAML to implement.
      worktree        — absolute path to the implementation worktree.
      target          — optional core name; when set, RTL lives in
                        cores/<target>/rtl/ instead of rtl/.

    Returns True if the post-implementation verilator lint succeeds.
    """
    with open(hypothesis_path) as f:
        hypothesis = yaml.safe_load(f)

    prompt = _build_prompt(hypothesis, worktree, target=target)
    log_path = Path(worktree) / ".agent.log"
    last_msg = Path(worktree) / ".agent.last"
    cmd = build_agent_cmd(
        prompt, cwd=worktree,
        output_last_message=last_msg,
        enable_search=False,  # implementation runs in the worktree, no search needed
    )
    rc, timed_out = run_agent_streaming(
        cmd, cwd=worktree, log_path=log_path, timeout_sec=CLAUDE_TIMEOUT_SEC,
    )
    if rc != 0 and not timed_out:
        # See hypothesis.py for the append-on-retry rationale.
        print(f"  [agent] non-zero exit ({rc}); retrying once", flush=True)
        with log_path.open("a") as log:
            log.write(f'\n{{"type":"retry_marker","first_rc":{rc}}}\n')
        rc, timed_out = run_agent_streaming(
            cmd, cwd=worktree, log_path=log_path, timeout_sec=CLAUDE_TIMEOUT_SEC,
            mode="a",
        )
    if timed_out:
        print(f"  [agent] TIMEOUT after {CLAUDE_TIMEOUT_SEC}s — process killed",
              flush=True)

    # Lint as the smoke gate. Subsequent eval gates (formal, cosim, fpga)
    # exercise actual behavior; this catches the most basic SV breakage.
    rtl_glob = f"cores/{target}/rtl/*.sv" if target else "rtl/*.sv"
    rtl_dir_label = f"cores/{target}/rtl" if target else "rtl"
    lint_cmd = (f"if ls {rtl_glob} >/dev/null 2>&1; then "
                f"verilator --lint-only -Wall -Wno-MULTITOP -sv {rtl_glob}; "
                f"else echo 'lint: no source files in {rtl_dir_label}/'; exit 1; fi")
    lint = subprocess.run(
        ["bash", "-lc", lint_cmd],
        cwd=worktree, capture_output=True,
    )
    return lint.returncode == 0
