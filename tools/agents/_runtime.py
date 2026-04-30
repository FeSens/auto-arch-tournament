"""Agent-runtime abstraction: codex (default), claude, or pi.

Selected via AGENT_PROVIDER env var. Default `codex`. All runtimes are
invoked via subprocess and stream stdout to a per-slot log file.

Codex (default):
  codex --ask-for-approval never [--search] exec
        -C <cwd> --sandbox workspace-write
        --output-last-message <path> [--model <m>] <prompt>

Claude:
  claude -p <prompt> --dangerously-skip-permissions
         --output-format stream-json --verbose [--model <m>]

Pi (@mariozechner/pi-coding-agent):
  pi -p <prompt> --mode json --model <PI_MODEL>
     --tools read,write,edit,bash,grep,find,ls
  Pi auto-loads any extension in <cwd>/.pi/extensions/. The benchmark
  runner places `bench-fence` there to enforce path allowlists per run.
  Model selected via PI_MODEL env var, e.g. `anthropic/claude-opus-4-7`
  or `openrouter/qwen/qwen3-coder`. API keys come from native env vars
  (ANTHROPIC_API_KEY, OPENAI_API_KEY, OPENROUTER_API_KEY, ...).

All three produce streamed stdout. Claude's NDJSON tool_use and pi's
--mode json events get parsed into one-line "[<provider>] Edit: file.py"
prints; codex's --json events are similarly summarized.
"""
from __future__ import annotations

import json
import os
import subprocess
import threading
from pathlib import Path
from typing import Optional


VALID_PROVIDERS = ("codex", "claude", "pi")

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

    Codex --json format (verified via live probe):
      {"type": "thread.started", "thread_id": "..."}
      {"type": "turn.started"}
      {"type": "item.completed", "item": {"id": "...", "type": "<snake_case>", ...}}
      {"type": "turn.completed", "usage": {...}}

    We only summarize `item.completed` events; everything else is control flow.
    Inner item types are snake_case. Defensive `.get()` chains so a small
    schema change doesn't crash; unknown inner types fall back to
    `codex: <type>` so we know to add a handler.
    """
    et = ev.get("type")
    # Skip thread/turn/item.started + turn.completed control events.
    if et in (None,
              "thread.started", "thread.completed",
              "turn.started",   "turn.completed",
              "item.started"):
        return None
    if et != "item.completed":
        # Surface unknown top-level events with their type so we know to
        # extend the parser.
        return f"codex/{et}"

    item = ev.get("item") or {}
    if not isinstance(item, dict):
        return None
    t = item.get("type")
    if t in (None, "user_message", "hook_prompt", "reasoning"):
        return None
    if t == "agent_message":
        text = item.get("text") or item.get("message") or ""
        first = text.splitlines()[0] if isinstance(text, str) and text else ""
        return _truncate(f"msg: {first}", 120) if first else None
    if t == "command_execution":
        cmd = item.get("command") or item.get("cmd") or ""
        if isinstance(cmd, list):
            cmd = " ".join(cmd)
        return _truncate(f"shell: {cmd}", 120)
    if t == "file_change":
        # Inner item's type is "file_change"; the add/delete/update kind
        # lives in a different field — try a few names defensively.
        change = (item.get("change_type")
                  or item.get("kind")
                  or item.get("subtype")
                  or "change")
        path = (item.get("path")
                or item.get("file_path")
                or item.get("file")
                or "")
        if path:
            return _truncate(f"file({change}): {path}", 120)
        return f"file_change"
    if t == "web_search":
        q = item.get("query") or ""
        return _truncate(f"search: {q}", 120) if q else "web_search"
    if t == "plan":
        return "plan: (generated)"
    if t == "mcp_tool_call":
        name = item.get("name") or item.get("tool") or ""
        return _truncate(f"mcp: {name}", 120) if name else "mcp_tool_call"
    if t == "dynamic_tool_call":
        name = item.get("name") or item.get("tool") or ""
        return _truncate(f"tool: {name}", 120) if name else "dynamic_tool_call"
    if t == "collab_agent_tool_call":
        return "spawn-agent"
    if t in ("image_view", "image_generation"):
        return t
    if t in ("entered_review_mode", "exited_review_mode", "context_compaction"):
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
    """Return 'codex' (default), 'claude', or 'pi' from AGENT_PROVIDER env var."""
    p = os.environ.get("AGENT_PROVIDER", "codex").strip().lower()
    if p not in VALID_PROVIDERS:
        raise ValueError(
            f"AGENT_PROVIDER must be one of {VALID_PROVIDERS!r}, got {p!r}"
        )
    return p


def _summarize_pi_jsonl(ev: dict) -> Optional[str]:
    """One-liner from a pi --mode json event line.

    Pi's exact event grammar isn't fully nailed down in pi-mono's docs, so
    this parser is permissive. Recognized event types fall back to
    `pi: <type>` so unknown shapes surface in the log instead of crashing.

    Common shapes (best-effort):
      {"type": "tool_call",       "name": "edit", "input": {...}}
      {"type": "tool_result",     "name": "edit", ...}
      {"type": "assistant_message", "text": "..."}
      {"type": "thread.started"}  / "turn.started" / "turn.completed"
      {"type": "error", "message": "..."}
    """
    et = ev.get("type")
    if et in (None,
              "thread.started", "thread.completed",
              "turn.started", "turn.completed",
              "tool_result"):
        return None
    if et == "tool_call":
        name = ev.get("name") or ev.get("tool") or "?"
        inp = ev.get("input") or {}
        target = (inp.get("file_path")
                  or inp.get("path")
                  or inp.get("command")
                  or inp.get("pattern")
                  or inp.get("query")
                  or "")
        if isinstance(target, list):
            target = " ".join(str(x) for x in target)
        if isinstance(target, str) and len(target) > 100:
            target = target[:97] + "..."
        return f"{name}: {target}".rstrip(": ").strip()
    if et == "assistant_message":
        text = ev.get("text") or ev.get("message") or ""
        if isinstance(text, str) and text.strip():
            first = text.strip().splitlines()[0]
            return _truncate(f"msg: {first}", 120)
        return None
    if et == "error":
        msg = ev.get("message") or ev.get("error") or "unknown"
        return _truncate(f"error: {msg}", 140)
    if et == "usage":
        # Per-call token/cost telemetry. Surface compactly so cost watchers
        # can grep for it.
        toks_in = ev.get("input_tokens") or ev.get("prompt_tokens")
        toks_out = ev.get("output_tokens") or ev.get("completion_tokens")
        cost = ev.get("cost_usd") or ev.get("cost")
        if toks_in is not None or cost is not None:
            return f"usage: in={toks_in} out={toks_out} cost={cost}"
        return None
    # Unknown event — surface so we know to add a handler.
    return f"pi: {et}"


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
        # CODEX_MODEL env var lets the bench runner pin a specific model
        # per (model, rep) job without depending on the user's global
        # ~/.codex/config.toml. An explicit `model=` kwarg still wins.
        codex_model = model or os.environ.get("CODEX_MODEL", "").strip()
        if codex_model:
            cmd += ["--model", codex_model]
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
    if p == "pi":
        # Pi requires a model — there's no useful default. The runner sets
        # PI_MODEL per (model, rep) job; an explicit `model=` kwarg
        # overrides for tests/manual use.
        pi_model = model or os.environ.get("PI_MODEL", "").strip()
        if not pi_model:
            raise ValueError(
                "pi runtime requires PI_MODEL env var or model= kwarg "
                "(e.g. 'anthropic/claude-opus-4-7', 'openrouter/qwen/qwen3-coder')"
            )
        cmd = [
            "pi", "-p", prompt,
            "--mode", "json",
            "--model", pi_model,
            "--tools", "read,write,edit,bash,grep,find,ls",
        ]
        # PI_SESSION_DIR (if set) is forwarded as --session-dir so the
        # bench runner can isolate per-clone session storage WITHOUT
        # also isolating ~/.pi/agent/auth.json (which it would if we
        # set the broader PI_CODING_AGENT_DIR). Sharing auth.json across
        # clones is required for OAuth-subscription providers (Codex,
        # Claude Pro, Copilot) where the user logs in once globally.
        session_dir = os.environ.get("PI_SESSION_DIR", "").strip()
        if session_dir:
            cmd += ["--session-dir", session_dir]
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
    if p == "pi":
        s = line.rstrip("\n")
        if not s.strip():
            return None
        try:
            ev = json.loads(s)
        except json.JSONDecodeError:
            # Plain-text line (banner, stack trace, etc). Trim and echo.
            if len(s) > 140:
                s = s[:137] + "..."
            return s.strip() or None
        return _summarize_pi_jsonl(ev)
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
