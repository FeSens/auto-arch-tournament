"""Invokes the active agent runtime (codex by default; claude opt-in via
AGENT_PROVIDER) in the worktree to implement a hypothesis."""
import os, subprocess, yaml
from pathlib import Path
from tools.agents._runtime import (
    build_agent_cmd,
    run_agent_streaming,
)

CLAUDE_TIMEOUT_SEC = 600*3  # 10 min watchdog on the implementation agent

def _build_prompt(hypothesis: dict, worktree: str,
                  target: str | None = None) -> str:
    # E1c attribution control: BENCH_PROMPT_PROFILE=naive drops the
    # knowledge sections (ARCHITECTURE.md, CORE_PHILOSOPHY.md) while
    # keeping the mechanical contract (hypothesis body, source dump,
    # hard invariants, instructions) identical to the full profile.
    naive = os.environ.get("BENCH_PROMPT_PROFILE", "full") == "naive"
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

    philosophy = ""
    if target and not naive:
        philo_path = Path(worktree, "cores", target, "CORE_PHILOSOPHY.md")
        if philo_path.exists():
            philo_text = philo_path.read_text()
            if philo_text.strip():
                philosophy = (
                    f"## Core philosophy / architect's hard constraints\n"
                    f"{philo_text}\n\n"
                )

    arch_section = "" if naive else f"## Architecture\n{arch}\n\n"

    target_banner = ""
    if target:
        target_banner = f"""## ⚠️  TARGET CORE: cores/{target}/

You are working on **cores/{target}/** ONLY. The repository may contain
other cores (cores/baseline/, cores/v1/, etc.) that are visible from this
worktree — they are READ-ONLY REFERENCE, not your editing surface.

Edit ONLY: {rtl_rel}/*.sv  and  cores/{target}/test/test_*.py
Do NOT edit any other core's directory. The orchestrator's sandbox
will reject any edits outside cores/{target}/ as 'broken' and discard
your entire iteration's work.

"""

    return f"""You are a CPU RTL implementation agent.

Your job: implement the following architectural hypothesis in SystemVerilog.

{target_banner}{philosophy}## Hypothesis
Title: {hypothesis['title']}
Category: {hypothesis['category']}

Motivation:
{hypothesis['motivation']}

Proposed change:
{hypothesis['hypothesis']}

Advisory file changes (you may deviate, add, rename, or restructure freely):
{changes_str}

{arch_section}## Hard invariants and don't-touch list
{claude_md}

## Current SystemVerilog Source (your working directory)
{src_dump}

## Instructions
1. Implement the hypothesis by editing, creating, or restructuring files in {rtl_rel}/.
   You may create new files, delete files, merge files, or split files.
2. The top module MUST stay named `core` and expose the io_* RVFI port set.
   Do NOT modify anything in tools/, schemas/, formal/, fpga/, test/cosim/,
   bench/, ARCHITECTURE.md, CLAUDE.md, README.md, setup.sh, or Makefile.

   Do NOT write helper scripts at the workspace root or anywhere outside
   cores/{target}/. Files like `patch.py`, `patch_core.py`, `update_files.py`,
   or `apply.sh` are ALWAYS off-limits — even if they only edit allowed
   paths, the orchestrator's sandbox will flag them as `sandbox_violation`
   and discard your entire iteration. If your change spans many files,
   sequence multiple `edit` tool calls. Do not try to `cat <<EOF >` or
   `python3 patch.py` your way around the edit tool — `bash` redirects
   land in the wrong working directory anyway, so even if the sandbox
   permitted them they would write to the wrong tree.
3. After implementing, verify the build:
     verilator --lint-only -Wall -Wno-MULTITOP -sv +incdir+{rtl_rel} {rtl_rel}/*.sv
   Fix any errors / warnings before finishing.
4. Self-check formal locally before declaring done:
     bash formal/run_all.sh
   This is the same gate the orchestrator runs in Phase 4. Catching
   easy mistakes here (broken decoder arm, missed forwarding case,
   missing default in a case statement) saves an entire iteration
   getting marked broken on a one-line fix.

   Stage any scratch copies under $TMPDIR or ./.tmp inside the
   workspace; the sandbox rejects writes to /tmp or /private/tmp.

   The MOST COMMON formal failure is breaking the RVFI channel-0
   retirement contract: `io_rvfi_valid_0` must stay driven by the
   actual retirement signal (typically `mem_wb_w.valid`), and every
   channel-0 field must mirror the retiring instruction. If your
   change touches the writeback or commit path, re-read CLAUDE.md
   invariant #1 before declaring done — symptoms of breaking it are
   `formal_failed: no_checks_generated` or `*_ch0` PREUNSAT in the
   sby logs.

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
    rtl_dir_label = f"cores/{target}/rtl" if target else "rtl"
    rtl_dir = Path(worktree) / rtl_dir_label
    rtl_sources = sorted(rtl_dir.glob("*.sv"))
    core_pkg = rtl_dir / "core_pkg.sv"
    if core_pkg in rtl_sources:
        rtl_sources = [core_pkg, *(p for p in rtl_sources if p != core_pkg)]
    if not rtl_sources:
        return False
    lint = subprocess.run(
        [
            "verilator", "--lint-only", "-Wall", "-Wno-MULTITOP", "-sv",
            f"+incdir+{rtl_dir_label}",
            *(str(p.relative_to(worktree)) for p in rtl_sources),
        ],
        cwd=worktree, capture_output=True,
    )
    return lint.returncode == 0
