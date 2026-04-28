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

# Codex's `exec` mode prints a multi-line banner before doing work — model
# id, sandbox mode, token counters, separator dashes, etc. None of it is
# orchestrator-relevant signal, so we skip lines matching these prefixes
# in summarize_event. The full lines still go to the on-disk log; only the
# console echo is filtered.
_CODEX_BANNER_PREFIXES = (
    "Reading additional input from stdin",
    "OpenAI Codex",
    "workdir:",
    "model:",
    "provider:",
    "approval:",
    "sandbox:",
    "reasoning effort:",
    "reasoning summaries:",
    "session id:",
    "tokens used:",
    "--------",
    "----",
    "user instructions:",
    "User instructions:",
)


def _truncate(s: str, n: int = 100) -> str:
    s = s.replace("\n", " ").strip()
    return s if len(s) <= n else s[:n - 3] + "..."


def _summarize_codex_jsonl(ev: dict) -> Optional[str]:
    """One-liner from a codex --json event line.

    Codex wraps items in `{"method": "item/completed", "params": {"item": {...}}}`.
    We extract `params.item` and pick a short summary based on item type.
    Defensive — if a field we expect is missing, fall back to just the type
    name so the user still sees that something happened.
    """
    if ev.get("method") != "item/completed":
        return None
    item = (ev.get("params") or {}).get("item") or {}
    if not isinstance(item, dict):
        return None
    t = item.get("type")
    if t in (None, "userMessage", "hookPrompt", "reasoning"):
        # userMessage/hookPrompt are our own prompts echoed back; reasoning
        # is private chain-of-thought. None of these are orchestrator signal.
        return None
    if t == "agentMessage":
        text = item.get("text") or item.get("message") or ""
        first = text.splitlines()[0] if isinstance(text, str) and text else ""
        return _truncate(f"msg: {first}", 120) if first else None
    if t == "commandExecution":
        cmd = item.get("command") or item.get("cmd") or ""
        if isinstance(cmd, list):
            cmd = " ".join(cmd)
        return _truncate(f"shell: {cmd}", 120)
    if t == "fileChange":
        # The outer item "type" is "fileChange"; the inner change kind lives
        # under a separate field. We check known field names and fall back to
        # "change" if none are present.
        change = item.get("change_type") or item.get("subtype") or item.get("kind") or "change"
        path = item.get("path") or item.get("file_path") or item.get("file") or ""
        if path:
            return _truncate(f"file({change}): {path}", 120)
        return f"fileChange"
    if t == "webSearch":
        q = item.get("query") or ""
        return _truncate(f"search: {q}", 120) if q else "webSearch"
    if t == "plan":
        return "plan: (generated)"
    if t == "mcpToolCall":
        name = item.get("name") or item.get("tool") or ""
        return _truncate(f"mcp: {name}", 120) if name else "mcpToolCall"
    if t == "dynamicToolCall":
        name = item.get("name") or item.get("tool") or ""
        return _truncate(f"tool: {name}", 120) if name else "dynamicToolCall"
    if t == "collabAgentToolCall":
        return "spawn-agent"
    if t in ("imageView", "imageGeneration"):
        return t
    if t in ("enteredReviewMode", "exitedReviewMode", "contextCompaction"):
        return t
    # Unknown item type — surface it so we know to add a handler.
    return f"codex: {t}"


def _summarize_codex_plain(s: str) -> Optional[str]:
    """Fallback for non-JSON codex lines (banner, errors before --json kicks in).

    Existing logic: skip empty + banner-prefix lines, truncate the rest.
    """
    s = s.strip()
    if not s:
        return None
    if any(s.startswith(prefix) for prefix in _CODEX_BANNER_PREFIXES):
        return None
    if len(s) > 140:
        s = s[:137] + "..."
    return s


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
            "--skip-git-repo-check",
            "--json",
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
            # Insert after the prompt so cmd[2] stays the positional prompt
            # for any debugging tools that key on argv shape.
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
        s = line.rstrip("\n")
        if not s.strip():
            return None
        # Try JSONL first (codex --json mode). Fall back to plain-text +
        # banner-denylist for any line that doesn't parse — codex may emit
        # non-JSON banner / error lines (e.g. "ERROR: You've hit your usage
        # limit").
        try:
            ev = json.loads(s)
        except json.JSONDecodeError:
            return _summarize_codex_plain(s)
        return _summarize_codex_jsonl(ev)
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
