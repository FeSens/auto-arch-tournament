"""Agent-runtime abstraction: codex, claude, or opencode.

Selected via AGENT_PROVIDER env var. Default `codex`. All runtimes are
invoked via subprocess and stream stdout to a per-slot log file.

Codex (default):
  codex --ask-for-approval never [--search] exec
        -C <cwd> --sandbox workspace-write
        --output-last-message <path> [--model <m>] <prompt>

Claude:
  claude -p <prompt> --dangerously-skip-permissions
         --output-format stream-json --verbose [--model <m>]

OpenCode (sst/opencode):
  opencode run <prompt> --model <OPENCODE_MODEL> --format json
           --dangerously-skip-permissions --dir <cwd>
  Authenticated via `opencode providers login` (OAuth — Codex / Claude
  Pro / Copilot / Anthropic API key). Tool permissions configured via
  <cwd>/opencode.json. Like Codex CLI, opencode is workflow-trained
  for verify-then-declare, so no programmatic formal-fix needed.

All three produce streamed stdout. Claude's NDJSON and opencode's
--format json events get parsed into one-line
"[<provider>] Edit: file.py" prints; codex's --json events are
similarly summarized.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
from pathlib import Path
from typing import Optional


VALID_PROVIDERS = ("codex", "claude", "opencode", "static", "random")

# Claude Code tools a bench agent must not have. Web lookup matches the
# Codex runs (no --search). The rest reach outside the rep: messaging
# other local Claude sessions, phone notifications, remote triggers,
# jobs that outlive the process, multi-agent workflows, and worktrees
# the harness doesn't manage.
CLAUDE_BENCH_DISALLOWED_TOOLS = (
    "WebFetch", "WebSearch",
    "SendMessage", "ListAgents", "PushNotification", "RemoteTrigger",
    "CronCreate", "CronDelete", "CronList", "ScheduleWakeup",
    "Workflow", "DesignSync", "EnterWorktree", "ExitWorktree",
)

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
    """Return one of {'codex' (default), 'claude', 'opencode'} from AGENT_PROVIDER."""
    p = os.environ.get("AGENT_PROVIDER", "codex").strip().lower()
    if p not in VALID_PROVIDERS:
        raise ValueError(
            f"AGENT_PROVIDER must be one of {VALID_PROVIDERS!r}, got {p!r}"
        )
    return p


def _summarize_opencode_jsonl(ev: dict) -> Optional[str]:
    """One-liner from an opencode `--format json` event.

    Verified against opencode 1.14.30. Event shape:
      {"type": "step_start" | "step_finish" | "text" | "tool_use" | ...,
       "timestamp": ..., "sessionID": ..., "part": {...}}

    Inner `part` for tool_use:
      {"type": "tool", "tool": "bash" | "read" | "edit" | ...,
       "callID": ..., "state": {"input": {...}, "output": ..., "metadata": ...}}
    """
    et = ev.get("type")
    # Skip control events.
    if et in (None, "step_start", "step_finish",
              "session_start", "session_idle"):
        return None
    part = ev.get("part") or {}
    if not isinstance(part, dict):
        return None
    if et == "text":
        text = (part.get("text") or "").strip()
        if not text:
            return None
        first = text.splitlines()[0]
        return _truncate(f"msg: {first}", 120)
    if et == "tool_use":
        tool = part.get("tool") or "?"
        state = part.get("state") or {}
        inp = state.get("input") or {} if isinstance(state, dict) else {}
        target = (inp.get("file_path")
                  or inp.get("path")
                  or inp.get("filePath")
                  or inp.get("command")
                  or inp.get("pattern")
                  or inp.get("query")
                  or "")
        if isinstance(target, str) and len(target) > 100:
            target = target[:97] + "..."
        return f"{tool}: {target}".rstrip(": ").strip()
    if et == "error":
        msg = ev.get("message") or part.get("message") or "unknown"
        return _truncate(f"error: {msg}", 140)
    # Unknown — surface the type so parser drift is visible.
    return f"opencode: {et}"


# Directory under <clone>/.tmp where implementer and scribe transcripts
# are copied before the harness deletes them.
AGENT_LOG_ARCHIVE = "agent-logs"


def archive_agent_log(log_path: Path, name: str, repo: Path = Path(".")) -> None:
    """Copy one agent transcript into <repo>/.tmp/agent-logs/<name>.log
    (appending, so a retried or repeated agent keeps every attempt).
    Never raises: telemetry must not fail a slot."""
    try:
        if not log_path.is_file():
            return
        dest = repo / ".tmp" / AGENT_LOG_ARCHIVE / f"{name}.log"
        dest.parent.mkdir(parents=True, exist_ok=True)
        with open(log_path, "rb") as src, open(dest, "ab") as out:
            shutil.copyfileobj(src, out)
    except OSError:
        pass


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
        # Make reasoning effort explicit so the bench is reproducible
        # regardless of the user's ~/.codex/config.toml. xhigh matches
        # what real coding agent users run on the gpt-5 family per
        # OpenAI's own docs ("xhigh for the hardest asynchronous
        # agentic tasks or evals that test the bounds of model
        # intelligence"). Override per-job with CODEX_REASONING_EFFORT.
        codex_effort = os.environ.get("CODEX_REASONING_EFFORT", "xhigh").strip()
        if codex_effort:
            cmd += ["-c", f"model_reasoning_effort={codex_effort}"]
        cmd.append(prompt)
        return cmd
    if p == "claude":
        isolation = os.environ.get("CLAUDE_BENCH_SETTINGS", "").strip()
        if isolation:
            # Bench isolation (tools/bench/runner.py claude_isolation_settings):
            # no user/project settings, plugins, hooks, MCP or connectors;
            # Bash confined by the OS sandbox; file tools auto-approved only
            # inside cwd (acceptEdits), so reads/writes elsewhere are denied
            # in -p mode.
            cmd = [
                "claude", "-p", prompt,
                "--output-format", "stream-json",
                "--verbose",
                "--setting-sources", "",
                "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                "--permission-mode", "acceptEdits",
                "--settings", isolation,
                "--disallowedTools", *CLAUDE_BENCH_DISALLOWED_TOOLS,
            ]
            effort = os.environ.get("CLAUDE_EFFORT", "").strip()
            if effort:
                cmd += ["--effort", effort]
        else:
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
    if p == "opencode":
        # Opencode reads its model from --model; OPENCODE_MODEL env var
        # is the bench-runner convention. No useful default.
        opencode_model = model or os.environ.get("OPENCODE_MODEL", "").strip()
        if not opencode_model:
            raise ValueError(
                "opencode runtime requires OPENCODE_MODEL env var or model= kwarg "
                "(e.g. 'openai/gpt-5.5', 'anthropic/claude-sonnet-4.6')"
            )
        cmd = [
            "opencode", "run", prompt,
            "--model", opencode_model,
            "--format", "json",
            "--dangerously-skip-permissions",
            "--dir", str(cwd),
        ]
        # Match codex's xhigh reasoning effort for apples-to-apples
        # comparison. opencode's --variant flag is documented as
        # "provider-specific reasoning effort" and the docs explicitly
        # list `xhigh - Extra high reasoning effort` for OpenAI
        # variants. Without this, opencode runs at its default
        # (medium-ish) and looks worse than codex purely because of
        # the effort gap, not the runtime. Override per-job with
        # OPENCODE_VARIANT — set it to "" to drop the flag entirely
        # (e.g. for non-OpenAI models that don't support xhigh).
        opencode_variant = os.environ.get("OPENCODE_VARIANT", "xhigh").strip()
        if opencode_variant:
            cmd += ["--variant", opencode_variant]
        # Optional override for opencode's --agent flag. Empty string
        # (the default) keeps opencode on its built-in default agent.
        opencode_agent = os.environ.get("OPENCODE_AGENT", "").strip()
        if opencode_agent:
            cmd += ["--agent", opencode_agent]
        return cmd
    if p == "static":
        # No-LLM control. tools/agents/static_agent.py writes a stub
        # hypothesis YAML or implementation_notes.md depending on
        # which phase's prompt it sees, makes no RTL changes, exits 0.
        # Used to characterize the harness's noise floor — any LLM
        # agent's measured fitness gain above the static-control's
        # delta is real signal.
        # `-B` keeps Python from writing bytecode artifacts into
        # tools/__pycache__/ inside the sub-worktree (which would be
        # caught by the orchestrator's sandbox check on tracked-pyc
        # mtime changes). worktree.py also assume-unchanged's any
        # tracked pyc paths as defense in depth, but `-B` is the
        # cleaner local fix.
        cmd = [sys.executable, "-B", "-m", "tools.agents.static_agent", prompt]
        if output_last_message is not None:
            cmd += ["--output-last-message", str(output_last_message)]
        return cmd
    if p == "random":
        # Seeded random-mutation control (E1b). Same invocation contract
        # as static; RANDOM_AGENT_SEED env drives determinism.
        cmd = [sys.executable, "-B", "-m", "tools.agents.random_agent", prompt]
        if output_last_message is not None:
            cmd += ["--output-last-message", str(output_last_message)]
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
    if p == "opencode":
        s = line.rstrip("\n")
        if not s.strip():
            return None
        try:
            ev = json.loads(s)
        except json.JSONDecodeError:
            # Plain-text line (banner, error before --format json kicks in).
            if len(s) > 140:
                s = s[:137] + "..."
            return s.strip() or None
        return _summarize_opencode_jsonl(ev)
    return None


# Variables an agent run as HWE_AGENT_USER inherits from the orchestrator.
# Everything else (the operator's HOME, PATH, shell state, unrelated
# secrets) is dropped.
_AGENT_ENV_PASS = (
    "TARGET", "TMPDIR", "LANG", "LC_ALL", "TERM", "GOWIN_HOME",
    "CODEX_HOME", "CODEX_MODEL", "CODEX_REASONING_EFFORT",
    "ANTHROPIC_MODEL", "CLAUDE_BENCH_SETTINGS", "CLAUDE_EFFORT",
    "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_DISABLE_AUTO_MEMORY",
    "DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "DISABLE_AUTOUPDATER",
)
_AGENT_ENV_PREFIXES = ("AGENT_", "BENCH_", "HWE_")


def as_agent_user(cmd: list[str], environ: Optional[dict] = None) -> list[str]:
    """Wrap cmd to run as HWE_AGENT_USER (V2 isolation) with a clean
    environment; unchanged when the variable is unset.

    The runner stays the operator; the agent CLI runs as an account that
    cannot read the operator's home (held-out kernels, results, other
    sessions). See research/v2/scripts/setup_bench_user.sh."""
    env = os.environ if environ is None else environ
    user = env.get("HWE_AGENT_USER", "").strip()
    if not user:
        return cmd
    home = env["HWE_AGENT_HOME"]
    keep = {k: v for k, v in env.items()
            if k in _AGENT_ENV_PASS or k.startswith(_AGENT_ENV_PREFIXES)}
    keep.update({
        "HOME": home, "USER": user, "LOGNAME": user, "SHELL": "/bin/zsh",
        "PATH": env["HWE_AGENT_PATH"],
        "PYTHONUSERBASE": env.get("HWE_AGENT_PYTHONUSERBASE", ""),
        # The clone belongs to the operator; git refuses it otherwise.
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "safe.directory", "GIT_CONFIG_VALUE_0": "*",
    })
    assigns = [f"{k}={v}" for k, v in sorted(keep.items()) if v != ""]
    # umask 007: nothing the agent writes is readable by other accounts
    # (concurrent runs hold different accounts; /tmp is shared). Inside the
    # clone the directory's default ACL still gives the operator access.
    # nice 10: the agents' own self-checks (formal, Gowin) yield the CPU to
    # the harness's scoring evals, so a score never depends on how hard
    # another run's agent is working (same for every system).
    return ["sudo", "-n", "-u", user, "/usr/bin/nice", "-n", "10", "/usr/bin/env", "-i", *assigns,
            "/bin/sh", "-c", 'umask 007; exec "$@"', "sh", *cmd]


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
        as_agent_user(cmd), cwd=cwd,
        stdin=subprocess.DEVNULL,
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
            # The agent's own shells and tools die with it.
            from tools.eval._subprocess import kill_process_tree
            kill_process_tree(proc.pid)

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
