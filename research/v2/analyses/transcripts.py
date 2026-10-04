"""Parse each run's agent.full.log.gz into per-agent-session records.

agent.full.log.gz concatenates every agent session of a run, each under a
header line `=== <path> ===`:
  .../hypotheses/.agent.<hyp-id>.log   hypothesis agent
  .../agent-logs/impl.<hyp-id>.log     implementation agent
  .../agent-logs/scribe.<hyp-id>.log   scribe (lesson writer)
Claude Code sessions are stream-json (assistant tool_use events, a final
`result` event); Codex sessions are `codex exec --json` events
(item.started/item.completed with command_execution and file_change items,
`turn.completed` with usage).

For every session this module records, in order, the shell commands it ran
and the files it edited, whether the session finished on its own (a Claude
`result` event or a Codex `turn.completed`; a session killed by the harness
watchdog has neither), and its token usage (same accounting as
tools/bench/telemetry.py: gross input including cache reads, output including
reasoning). Command text is kept only in memory; the cache written to
results/ holds check flags and counts, never raw commands.
"""
from __future__ import annotations

import gzip
import json
import re
import shlex
from pathlib import Path

from common import MODELS, OUT, REPS, run_dir

HEADER = re.compile(r"^=== (/\S+\.log) ===$")
# run_all.sh's summary line, seen in a command's output.
FORMAL_SUMMARY = re.compile(r"Formal: (\d+) passed, (\d+) failed")


def _formal_summaries(text: str):
    return [(int(a), int(b)) for a, b in FORMAL_SUMMARY.findall(text or "")]


def section_role(path: str) -> tuple[str, str]:
    name = path.rsplit("/", 1)[-1]
    if name == ".agent.log":
        # <worktree>/.agent.log: a copy of an implementation session left in a
        # worktree the harness did not delete (placement_failed slots).
        return "worktree_copy", path.rsplit("/", 2)[-2]
    if name.startswith(".agent."):
        return "hypothesis", name[len(".agent."):-len(".log")]
    if name.startswith("impl."):
        return "implementation", name[len("impl."):-len(".log")]
    if name.startswith("scribe."):
        return "scribe", name[len("scribe."):-len(".log")]
    return "other", name


def iter_sessions(model: str, rep: int):
    """Yield one dict per agent session: role, hyp_id, events, finished, tokens."""
    path = run_dir(model, rep) / "agent.full.log.gz"
    seen_paths = set()
    cur = None

    def finish(s):
        if s is None:
            return None
        # Claude sessions killed before their result event: recover tokens
        # from per-message usage, deduplicated by message id (telemetry.py).
        for sid, msgs in s["_claude_partial"].items():
            if sid in s["_claude_result"]:
                continue
            for u in msgs.values():
                s["tokens_in"] += int(u.get("input_tokens") or 0)
                s["tokens_in"] += int(u.get("cache_read_input_tokens") or 0)
                s["tokens_in"] += int(u.get("cache_creation_input_tokens") or 0)
                s["tokens_out"] += int(u.get("output_tokens") or 0)
        s["n_cli_sessions"] = len(set(s["_claude_partial"]) | s["_claude_result"]) or s.get("n_cli_sessions", 0)
        for k in ("_claude_partial", "_claude_result", "_ids", "_uuids"):
            s.pop(k, None)
        return s

    with gzip.open(path, "rt", errors="replace") as f:
        for line in f:
            m = HEADER.match(line.rstrip("\n"))
            if m:
                done = finish(cur)
                if done:
                    yield done
                p = m.group(1)
                role, hid = section_role(p)
                dup = p in seen_paths
                seen_paths.add(p)
                cur = None if dup else {
                    "role": role, "hyp_id": hid, "events": [], "finished": False,
                    "vendor": None, "tokens_in": 0, "tokens_out": 0,
                    "_claude_partial": {}, "_claude_result": set(), "_ids": set(), "_uuids": set(),
                }
                continue
            if cur is None or not line.startswith("{"):
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(ev, dict):
                continue
            t = ev.get("type")
            # ---- Codex
            if t in ("item.started", "item.completed"):
                cur["vendor"] = "codex"
                it = ev.get("item") or {}
                key = it.get("id")
                if key in cur["_ids"]:
                    if t == "item.completed" and it.get("type") == "command_execution":
                        for ps in _formal_summaries(it.get("aggregated_output") or ""):
                            cur["events"].append(("formal_summary", ps))
                    continue
                cur["_ids"].add(key)
                if it.get("type") == "command_execution":
                    cur["events"].append(("cmd", it.get("command") or ""))
                    for ps in _formal_summaries(it.get("aggregated_output") or ""):
                        cur["events"].append(("formal_summary", ps))
                elif it.get("type") == "file_change":
                    for ch in it.get("changes") or []:
                        cur["events"].append(("edit", ch.get("path") or ""))
            elif t == "turn.completed":
                cur["vendor"] = "codex"
                cur["finished"] = True
                u = ev.get("usage") or {}
                cur["tokens_in"] += int(u.get("input_tokens") or 0)
                cur["tokens_out"] += int(u.get("output_tokens") or 0)
                cur["tokens_out"] += int(u.get("reasoning_output_tokens") or 0)
            # ---- Claude Code
            elif t == "assistant":
                cur["vendor"] = "claude"
                msg = ev.get("message") or {}
                u = msg.get("usage")
                if isinstance(u, dict) and msg.get("id"):
                    cur["_claude_partial"].setdefault(ev.get("session_id") or "", {})[msg["id"]] = u
                for c in msg.get("content") or []:
                    if not isinstance(c, dict) or c.get("type") != "tool_use":
                        continue
                    key = c.get("id")
                    if key in cur["_ids"]:
                        continue
                    cur["_ids"].add(key)
                    name = c.get("name") or ""
                    inp = c.get("input") or {}
                    if name.lower() == "bash":
                        cur["events"].append(("cmd", inp.get("command") or ""))
                    elif name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
                        cur["events"].append(("edit", inp.get("file_path") or inp.get("notebook_path") or ""))
            elif t == "user":
                for c in (ev.get("message") or {}).get("content") or []:
                    if not isinstance(c, dict) or c.get("type") != "tool_result":
                        continue
                    body = c.get("content")
                    if isinstance(body, list):
                        body = "\n".join(b.get("text", "") for b in body if isinstance(b, dict))
                    for ps in _formal_summaries(body if isinstance(body, str) else ""):
                        cur["events"].append(("formal_summary", ps))
            elif t == "result":
                cur["vendor"] = "claude"
                key = ev.get("uuid") or line
                if key in cur["_uuids"]:
                    continue
                cur["_uuids"].add(key)
                cur["_claude_result"].add(ev.get("session_id") or "")
                cur["finished"] = True
                usage = ev.get("modelUsage")
                if isinstance(usage, dict) and usage:
                    for mu in usage.values():
                        if isinstance(mu, dict):
                            cur["tokens_in"] += int(mu.get("inputTokens") or 0)
                            cur["tokens_in"] += int(mu.get("cacheReadInputTokens") or 0)
                            cur["tokens_in"] += int(mu.get("cacheCreationInputTokens") or 0)
                            cur["tokens_out"] += int(mu.get("outputTokens") or 0)
                else:
                    u = ev.get("usage") or {}
                    cur["tokens_in"] += int(u.get("input_tokens") or 0)
                    cur["tokens_in"] += int(u.get("cache_read_input_tokens") or 0)
                    cur["tokens_in"] += int(u.get("cache_creation_input_tokens") or 0)
                    cur["tokens_out"] += int(u.get("output_tokens") or 0)
    done = finish(cur)
    if done:
        yield done


# ---- shell command parsing ------------------------------------------------------

_CODEX_WRAP = re.compile(r"^\s*/bin/(?:ba)?sh\s+-l?c\s+")
_HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_WRAPPERS = {"timeout", "nice", "env", "time", "nohup", "exec", "stdbuf", "ionice", "setsid", "xargs"}


def unwrap(cmd: str) -> str:
    """Codex runs every command as `/bin/bash -c '<script>'`; return the script."""
    m = _CODEX_WRAP.match(cmd)
    if not m:
        return cmd
    rest = cmd[m.end():]
    try:
        parts = shlex.split(rest)
        if parts:
            return parts[0]
    except ValueError:
        pass
    if len(rest) >= 2 and rest[0] in "'\"" and rest[-1] == rest[0]:
        return rest[1:-1]
    return rest


def split_heredocs(script: str) -> tuple[str, list[str]]:
    """Remove heredoc bodies from a script; return (script, bodies)."""
    lines = script.split("\n")
    out, bodies = [], []
    i = 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        delims = [m.group(2) for m in _HEREDOC.finditer(line)]
        i += 1
        for d in delims:
            body = []
            while i < len(lines) and lines[i].strip() != d:
                body.append(lines[i])
                i += 1
            i += 1  # skip the delimiter line
            bodies.append("\n".join(body))
    return "\n".join(out), bodies


def simple_commands(script: str, depth: int = 0) -> list[list[str]]:
    """Split a shell script into simple commands (argv lists), unwrapping
    `bash -c '...'` and leading env assignments / timeout / nice wrappers."""
    script, _ = split_heredocs(script)
    script = script.replace("\\\n", " ")
    lines = [ln for ln in script.split("\n") if not ln.lstrip().startswith("#")]
    try:
        lex = shlex.shlex(" ; ".join(lines), posix=True, punctuation_chars=";&|()<>")
        lex.whitespace_split = True
        lex.commenters = ""
        toks = list(lex)
    except ValueError:
        # Unbalanced quotes: fall back to per-line, whitespace tokens.
        toks = []
        for ln in lines:
            try:
                l2 = shlex.shlex(ln, posix=True, punctuation_chars=";&|()<>")
                l2.whitespace_split = True
                l2.commenters = ""
                toks += list(l2) + [";"]
            except ValueError:
                toks += re.split(r"\s+|(?=[;&|()])|(?<=[;&|()])", ln) + [";"]
    cmds, cur, skip_next = [], [], False
    for t in toks:
        if not t:
            continue
        if skip_next:
            skip_next = False
            continue
        if set(t) <= set(";&|()"):
            if cur:
                cmds.append(cur)
            cur = []
            continue
        if set(t) <= set("<>&") or t in (">", ">>", "<", "2>", "&>"):
            skip_next = True  # redirection target
            continue
        cur.append(t)
    if cur:
        cmds.append(cur)
    result = []
    for argv in cmds:
        argv = [a for a in argv if a not in ("{", "}", "!")]
        while argv and (_ASSIGN.match(argv[0]) or argv[0] in ("then", "do", "else", "elif", "if", "while", "until")):
            argv = argv[1:]
        # wrappers: timeout [opts] DURATION cmd..., nice [-n N] cmd..., env [VAR=..] cmd...
        changed = True
        while argv and changed:
            changed = False
            prog = argv[0].rsplit("/", 1)[-1]
            if prog in _WRAPPERS:
                rest = argv[1:]
                while rest and (rest[0].startswith("-") or _ASSIGN.match(rest[0])):
                    opt = rest.pop(0)
                    if opt in ("-n", "-s", "-k", "--signal", "--kill-after", "-o", "-e", "-i") and rest:
                        rest.pop(0)
                if prog == "timeout" and rest:
                    rest = rest[1:]  # the duration
                argv, changed = rest, True
        if not argv:
            continue
        prog = argv[0].rsplit("/", 1)[-1]
        if prog in ("bash", "sh") and depth < 3:
            for flag in ("-c", "-lc", "-ec", "-xc"):
                if flag in argv:
                    k = argv.index(flag)
                    if k + 1 < len(argv):
                        result += simple_commands(argv[k + 1], depth + 1)
                    break
            else:
                result.append(argv)
            continue
        result.append(argv)
    return result


def _python_module(argv):
    if "-m" in argv:
        k = argv.index("-m")
        if k + 1 < len(argv):
            return argv[k + 1]
    return None


CHECKS = ("formal", "cosim", "lint", "timing", "cocotb", "own_sim")


def classify_argv(argv: list[str]) -> set[str]:
    """Which harness check a simple command runs (empty set: none)."""
    found = set()
    if not argv:
        return found
    prog = argv[0].rsplit("/", 1)[-1]
    args = argv[1:]
    nonopt = [a for a in args if not a.startswith("-")]
    if prog in ("bash", "sh", "source", "."):
        if nonopt and nonopt[0].endswith("formal/run_all.sh"):
            found.add("formal")
        if nonopt and nonopt[0].endswith("test/cosim/run_cosim.py"):
            found.add("cosim")
    elif argv[0].endswith("formal/run_all.sh"):
        found.add("formal")
    elif prog in ("make", "gmake"):
        targets = [a for a in nonopt if "=" not in a]
        if any(t in ("formal", "formal-deep") for t in targets):
            found.add("formal")
        if "cosim" in targets:
            found.add("cosim")
        if "lint" in targets:
            found.add("lint")
        if "timing" in targets or "fpga" in targets:
            found.add("timing")
        if "test" in targets:
            found.add("cocotb")
    elif prog == "sby":
        if any(a.endswith(".sby") or a == "-f" for a in args):
            found.add("formal")
    elif prog.startswith("python"):
        mod = _python_module(argv)
        if mod == "tools.eval.formal":
            found.add("formal")
        elif mod == "tools.eval.cosim":
            found.add("cosim")
        elif mod in ("tools.eval.gowin", "tools.eval.fpga"):
            found.add("timing")
        elif mod == "pytest":
            found.add("cocotb")
        elif nonopt and nonopt[0].endswith("run_cosim.py"):
            found.add("cosim")
        if "-c" in args:
            code = args[args.index("-c") + 1] if args.index("-c") + 1 < len(args) else ""
            found |= classify_python_code(code)
    elif prog in ("pytest", "py.test"):
        found.add("cocotb")
    elif prog == "verilator":
        if "--lint-only" in args:
            found.add("lint")
        elif any(a in ("--binary", "--cc", "--exe", "--build", "--main") for a in args):
            found.add("own_sim")
    elif prog in ("iverilog", "vvp"):
        found.add("own_sim")
    elif prog == "cosim_sim" or argv[0].endswith("obj_dir/cosim_sim"):
        found.add("cosim")
    elif prog == "gw_sh":
        found.add("timing")
    return found


def classify_python_code(code: str) -> set[str]:
    """Python run from a heredoc or -c that calls a harness check module."""
    found = set()
    if re.search(r"tools\.eval\.gowin\b|IDE/bin/gw_sh|['\"]gw_sh['\"]|run_fpga_eval|fpga\.run_|from tools\.eval\.fpga import (?!run_coremark_ipc\b)", code):
        found.add("timing")
    if re.search(r"tools\.eval\.cosim\b|run_cosim\b|run_coremark_ipc\b", code):
        found.add("cosim")
    if re.search(r"formal/run_all\.sh|tools\.eval\.formal\b", code) and re.search(r"subprocess|os\.system", code):
        found.add("formal")
    return found


def classify_command(cmd: str) -> set[str]:
    script = unwrap(cmd)
    found = set()
    _, bodies = split_heredocs(script)
    argvs = simple_commands(script)
    for argv in argvs:
        found |= classify_argv(argv)
    # heredoc bodies fed to python (python3 - <<'PY')
    if bodies and any(a and a[0].rsplit("/", 1)[-1].startswith("python") for a in argvs):
        for b in bodies:
            found |= classify_python_code(b)
    return found


_RTL_PATH = re.compile(r"(?:cores/bench/)?rtl/[^\s'\"]*\.s?v\b")
_CD_RTL = re.compile(r"\bcd\s+\S*rtl\b")
_SV_NAME = re.compile(r"\b\w+\.s?v\b")
_SHELL_EDIT = re.compile(r"\bsed\s+-i|\bperl\s+-p?i|>\s*\S*\.s?v\b|\btee\s+\S*\.s?v\b|"
                         r"write_text\(|open\([^)]*['\"]w['\"]|\bmv\s+\S+\s+\S*cores/bench/rtl/|\bcp\s+\S+\s+\S*cores/bench/rtl/|"
                         r"git\s+(checkout|restore|apply|stash\s+pop)")


def is_rtl_edit_event(kind: str, payload: str) -> bool:
    if kind == "edit":
        return "/rtl/" in payload or payload.startswith("rtl/")
    if kind == "cmd":
        script = unwrap(payload)
        names_rtl = _RTL_PATH.search(script) or (_CD_RTL.search(script) and _SV_NAME.search(script))
        if names_rtl and "implementation_notes" in script:
            # notes text often names rtl/*.sv files; require a quoted .sv path
            # (how Python edit code names its file) or sed -i on a .sv file
            names_rtl = re.search(r"['\"][^'\"\s]*\.s?v['\"]|sed\s+-i[^;\n]*\.s?v\b", script)
        return bool(names_rtl and _SHELL_EDIT.search(script))
    return False


# ---- cache --------------------------------------------------------------------------

CACHE = OUT / "transcript_sessions.jsonl"


def session_record(model, rep, s) -> dict:
    counts = {c: 0 for c in CHECKS}
    last_rtl_edit = -1
    last_check = {c: -1 for c in CHECKS}
    n_cmd = 0
    last_summary, last_summary_idx = None, -1
    for i, (kind, payload) in enumerate(s["events"]):
        if kind == "formal_summary":
            last_summary, last_summary_idx = payload, i
            continue
        if is_rtl_edit_event(kind, payload):
            last_rtl_edit = i
        if kind != "cmd":
            continue
        n_cmd += 1
        for c in classify_command(payload):
            counts[c] += 1
            last_check[c] = i
    return {
        "model": model, "rep": rep, "role": s["role"], "hyp_id": s["hyp_id"],
        "vendor": s["vendor"], "finished": s["finished"],
        "tokens_in": s["tokens_in"], "tokens_out": s["tokens_out"],
        "n_events": len(s["events"]), "n_cmd": n_cmd,
        "n_rtl_edits": sum(1 for k, p in s["events"] if k != "formal_summary" and is_rtl_edit_event(k, p)),
        "checks": counts,
        # last run_all.sh summary the agent saw: [passed, failed] or None
        "last_formal_summary": list(last_summary) if last_summary else None,
        "last_formal_summary_after_last_edit": last_summary_idx > last_rtl_edit,
        # a check that ran after the last RTL edit (the shipped RTL was checked)
        "check_after_last_edit": {c: (last_check[c] > last_rtl_edit and last_check[c] >= 0) for c in CHECKS},
    }


def build_cache(force: bool = False) -> list[dict]:
    if CACHE.exists() and not force:
        return [json.loads(l) for l in CACHE.read_text().splitlines() if l.strip()]
    OUT.mkdir(parents=True, exist_ok=True)
    recs = []
    for m in MODELS:
        for r in REPS:
            for s in iter_sessions(m, r):
                recs.append(session_record(m, r, s))
            print(f"parsed {m} rep{r}", flush=True)
    with open(CACHE, "w") as f:
        for rec in recs:
            f.write(json.dumps(rec) + "\n")
    return recs


def matched_commands(model, rep, role="implementation", limit=None):
    """Audit helper (not written to disk by default): (hyp_id, checks, command)."""
    out = []
    for s in iter_sessions(model, rep):
        if s["role"] != role:
            continue
        for kind, payload in s["events"]:
            if kind == "cmd":
                c = classify_command(payload)
                out.append((s["hyp_id"], sorted(c), payload))
        if limit and len(out) >= limit:
            break
    return out


if __name__ == "__main__":
    import sys
    build_cache(force="--force" in sys.argv)
