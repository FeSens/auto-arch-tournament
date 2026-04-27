"""Agent-runtime abstraction: codex (default) or claude.

Selected via AGENT_PROVIDER env var. Default `codex`. Both runtimes are
invoked via subprocess with workspace-write equivalents and stream stdout
to a per-slot log file.

Codex (default):
  codex --ask-for-approval never [--search] exec
        -C <cwd> --sandbox workspace-write
        --output-last-message <path> [--model <m>] <prompt>

Claude:
  claude -p <prompt> --dangerously-skip-permissions
         --output-format stream-json --verbose [--model <m>]

Both produce streamed stdout. Claude's NDJSON tool_use events get parsed
into one-line "[claude] Edit: file.py" prints; codex's text output is
just trimmed and echoed.
"""
from __future__ import annotations

import json
import os
import subprocess
import threading
from pathlib import Path
from typing import Optional


VALID_PROVIDERS = ("codex", "claude")


def get_provider() -> str:
    """Return 'codex' (default) or 'claude' from AGENT_PROVIDER env var."""
    p = os.environ.get("AGENT_PROVIDER", "codex").strip().lower()
    if p not in VALID_PROVIDERS:
        raise ValueError(
            f"AGENT_PROVIDER must be one of {VALID_PROVIDERS!r}, got {p!r}"
        )
    return p


def build_agent_cmd(
    prompt: str,
    cwd: str,
    output_last_message: Optional[Path] = None,
    model: Optional[str] = None,
    provider: Optional[str] = None,
    enable_search: bool = False,
) -> list[str]:
    """Build the CLI command for the active agent runtime.

    output_last_message — required for codex (it writes its final response there);
    ignored for claude.
    enable_search — codex --search; ignored for claude (claude has its own tools).
    """
    p = provider or get_provider()
    if p == "codex":
        if output_last_message is None:
            raise ValueError("codex runtime requires output_last_message")
        cmd = ["codex", "--ask-for-approval", "never"]
        if enable_search:
            cmd.append("--search")
        cmd += [
            "exec",
            "-C", str(cwd),
            "--sandbox", "workspace-write",
            "--output-last-message", str(output_last_message),
        ]
        if model:
            cmd += ["--model", model]
        cmd.append(prompt)
        return cmd
    if p == "claude":
        cmd = [
            "claude", "-p", prompt,
            "--dangerously-skip-permissions",
            "--output-format", "stream-json",
            "--verbose",
        ]
        if model:
            # Insert before --dangerously-skip-permissions so positional `prompt`
            # stays at index 2.
            cmd[3:3] = ["--model", model]
        return cmd
    raise ValueError(f"unknown provider {p!r}")


def summarize_event(line: str, provider: Optional[str] = None) -> Optional[str]:
    """Best-effort one-liner from a streamed event.

    Claude (NDJSON stream-json): parses tool_use events into "Tool: target".
    Codex (plain text): trims/truncates the line, dropping empty + control lines.

    Failures must NOT raise — the on-disk log is authoritative.
    """
    p = provider or get_provider()
    if p == "claude":
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
    if p == "codex":
        s = line.rstrip("\n").strip()
        if not s:
            return None
        # Codex writes a leading timestamp/banner line; let it through but
        # truncate so console stays tidy.
        if len(s) > 140:
            s = s[:137] + "..."
        return s
    return None


def run_agent_streaming(
    cmd: list,
    cwd: str,
    log_path: Path,
    timeout_sec: int,
    mode: str = "w",
    provider: Optional[str] = None,
) -> tuple[int, bool]:
    """Run an agent CLI with streaming, watchdog, per-line summaries.

    Returns (returncode, timed_out). Caller decides retry/fail.
    Identical implementation across providers; only the cmd shape and the
    summarize-event grammar differ.
    """
    p = provider or get_provider()
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

    with log_path.open(mode) as log:
        for line in proc.stdout:
            log.write(line)
            log.flush()
            try:
                summary = summarize_event(line, provider=p)
            except Exception:
                summary = None
            if summary:
                print(f"  [{p}] {summary}", flush=True)
    proc.wait()
    return proc.returncode, timed_out['flag']
