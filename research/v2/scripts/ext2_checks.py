#!/usr/bin/env python3
"""Gate checks for the amendment 17 systems (GPT-6.2 Astra, GPT-6.2 Sol, Fable 5.2).

Used on every smoke row before scored reps start, and on every finished rep row
while the campaign runs. Each check returns (fails, reviews): a fail stops a
launch outright; a review item is a difference from the earlier systems that
the operator must look at before the launch goes on (ext2_launcher.py waits for
an ack file that lists exactly the reviewed items).

  python3 research/v2/scripts/ext2_checks.py row <results.jsonl> <model> <rep>
  python3 research/v2/scripts/ext2_checks.py claude <rep_dir> <model> <cli_version>
  python3 research/v2/scripts/ext2_checks.py codex <rep_dir> <model> <cli_version> [<clone_dir>]

Exit status 0 when there is no fail (reviews are printed either way).
"""
import ast
import gzip
import json
import sys
from pathlib import Path

HARNESS = "2.8.4"
FIXTURE_COMMIT = "072e7ea85bffbb2baed647301ae61fbf0d91e4aa"   # bench-v2.8.4 = hwe-bench-v2.8.4
HOLDOUT_KERNELS = 5

# Claude Code init event of every Opus 5.5 (2.1.283) and Sonnet 5.5 (2.1.284) session
# (e.g. bench/v2/claude-sonnet-5-5_xhigh-v2/rep1/sandbox-probe-agent.log).
CLAUDE_BASE = {
    "tools": ["Task", "Bash", "Edit", "NotebookEdit", "Read", "ReportFindings", "Skill",
              "TaskStop", "Write"],
    "mcp_servers": [],
    "permissionMode": "acceptEdits",
    "plugins": [{"name": "agents-md", "path": "builtin", "source": "agents-md@builtin"}],
    "agents": ["claude", "Explore", "general-purpose", "Plan", "statusline-setup"],
    "skills": ["deep-research", "design", "design-sync", "dataviz", "update-config", "verify",
               "debug", "code-review", "simplify", "batch", "fewer-permission-prompts", "doctor",
               "loop", "schedule", "claude-api", "workflow-authoring", "run",
               "run-skill-generator"],
    "fast_mode_state": "off",
}
# Claude Code 2.1.327 ships agents-md as cc-plugin-agents-md plus two more built-in plugins
# and the plugin-authoring skill; amendment 18 accepts exactly this set (operator, 2026-11-23).
CLAUDE_BASE_BY_CLI = {
    "2.1.327": {
        **CLAUDE_BASE,
        "plugins": [
            {"name": "cc-plugin-agents-md", "path": "builtin", "source": "cc-plugin-agents-md@builtin"},
            {"name": "cc-plugin-privacy", "path": "builtin", "source": "cc-plugin-privacy@builtin"},
            {"name": "cc-plugin-plugin-authoring", "path": "builtin",
             "source": "cc-plugin-plugin-authoring@builtin"},
        ],
        "skills": CLAUDE_BASE["skills"] + ["plugin-authoring"],
    },
}
# Strings that mean the sandbox did not start, the CLI did not know the model, or the
# CLI changed the effort on its own (2.1.314+ lowers a rejected effort and retries).
CLAUDE_BAD = ["unrecognized_model", "Sandbox is enabled but failed", "Sandboxing is disabled",
              "Invalid effort level"]


def rows(path: Path) -> list[dict]:
    out = []
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def row_gate(row: dict | None, model: str, cli: dict) -> tuple[list, list]:
    """cli: e.g. {"codex_cli": "0.170.0", "cli_dir": "cli/codex-0.170.0"}."""
    if row is None:
        return ["no row"], []
    want = {"model": model, "status": "done", "harness_version": HARNESS,
            "fixture_commit": FIXTURE_COMMIT, "runner_dirty": False, **cli}
    fails = [f"{k}={row.get(k)!r} (want {v!r})" for k, v in want.items() if row.get(k) != v]
    if not (row.get("sandbox_probe") or {}).get("ok"):
        fails.append(f"sandbox_probe={row.get('sandbox_probe')!r}")
    if not isinstance(row.get("holdout_geomean_iter_s"), (int, float)):
        fails.append(f"holdout_geomean_iter_s={row.get('holdout_geomean_iter_s')!r}")
    try:
        k = row.get("holdout_kernels")
        k = ast.literal_eval(k) if isinstance(k, str) else (k or {})
        ok = [n for n, v in k.items() if v.get("validated")]
        if len(ok) != HOLDOUT_KERNELS:
            fails.append(f"held-out kernels validated {len(ok)}/{HOLDOUT_KERNELS}: {sorted(k)}")
    except (ValueError, SyntaxError, AttributeError) as e:
        fails.append(f"holdout_kernels unreadable: {e}")
    reviews = []
    if row.get("broken"):
        reviews.append(f"broken slots {row.get('broken')} {row.get('broken_by_class')}")
    return fails, reviews


def _json_lines(text: str):
    for line in text.splitlines():
        if line.startswith("{"):
            try:
                yield json.loads(line)
            except ValueError:
                pass


def _rep_texts(rep_dir: Path) -> dict[str, str]:
    out = {}
    probe = rep_dir / "sandbox-probe-agent.log"
    if probe.exists():
        out["probe"] = probe.read_text(errors="replace")
    full = rep_dir / "agent.full.log.gz"
    if full.exists():
        with gzip.open(full, "rt", errors="replace") as f:
            out["agents"] = f.read()
    elif (rep_dir / "agent.log").exists():
        out["agents"] = (rep_dir / "agent.log").read_text(errors="replace")
    return out


def claude_gate(rep_dir: Path, model: str, cli_version: str) -> tuple[list, list]:
    texts = _rep_texts(rep_dir)
    fails, reviews = [], []
    if "probe" not in texts or "agents" not in texts:
        return [f"missing logs in {rep_dir}: have {sorted(texts)}"], []
    base = CLAUDE_BASE_BY_CLI.get(cli_version, CLAUDE_BASE)
    inits, models, usage_keys, results = 0, set(), set(), 0
    seen_diff = set()
    for src, text in texts.items():
        for ev in _json_lines(text):
            t = ev.get("type")
            if t == "system" and ev.get("subtype") == "init":
                inits += 1
                if ev.get("model") != model:
                    fails.append(f"{src} init model {ev.get('model')!r}")
                if ev.get("claude_code_version") != cli_version:
                    fails.append(f"{src} init claude_code_version {ev.get('claude_code_version')!r}")
                for key in ("tools", "mcp_servers", "permissionMode", "plugins"):
                    if ev.get(key) != base[key] and (key, json.dumps(ev.get(key))) not in seen_diff:
                        seen_diff.add((key, json.dumps(ev.get(key))))
                        fails.append(f"{src} init {key} {ev.get(key)!r} differs from the Opus/Sonnet "
                                     f"baseline {base[key]!r}")
                for key in ("agents", "skills", "fast_mode_state"):
                    if ev.get(key) != base[key] and (key, json.dumps(ev.get(key))) not in seen_diff:
                        seen_diff.add((key, json.dumps(ev.get(key))))
                        reviews.append(f"init {key} {ev.get(key)!r} differs from the baseline "
                                       f"{base[key]!r}")
            elif t == "assistant":
                m = (ev.get("message") or {}).get("model")
                if m:
                    models.add(m)
            elif t == "result":
                results += 1
                usage_keys |= set((ev.get("modelUsage") or {}).keys())
    if inits == 0:
        fails.append("no init event")
    if models - {model}:
        fails.append(f"assistant messages from other models: {sorted(models - {model})}")
    if usage_keys - {model}:
        fails.append(f"modelUsage keys other than {model}: {sorted(usage_keys - {model})}")
    for s in CLAUDE_BAD:
        n = sum(t.count(s) for t in texts.values())
        if n:
            fails.append(f"{n} x {s!r}")
    reviews.append(f"info: {inits} init events, {results} result events, assistant models "
                   f"{sorted(models)}, bwrap mentions {texts['agents'].count('bwrap:')}")
    return fails, reviews


def codex_gate(rep_dir: Path, model: str, cli_version: str,
               clone_dir: Path | None = None) -> tuple[list, list]:
    """Session files (model, effort, CLI version per turn) exist only in the clone's
    .codex-home, which the runner deletes; pass clone_dir for a --keep-clones smoke."""
    fails, reviews = [], []
    texts = _rep_texts(rep_dir)
    if "agents" not in texts:
        return [f"no agent log in {rep_dir}"], []
    spawn = texts["agents"].count("spawn_agent")
    if spawn:
        reviews.append(f"{spawn} spawn_agent mentions in the agent log (check model/effort overrides)")
    err_types = {}
    for ev in _json_lines(texts["agents"]):
        if ev.get("type") in ("error", "turn.failed"):
            msg = ev.get("message") or (ev.get("error") or {}).get("message") or ""
            err_types[msg[:120]] = err_types.get(msg[:120], 0) + 1
    if err_types:
        reviews.append(f"error events: {err_types}")
    if clone_dir is not None:
        sess = sorted((clone_dir / ".codex-home" / "sessions").rglob("*.jsonl"))
        if not sess:
            fails.append(f"no Codex session files under {clone_dir}/.codex-home/sessions")
        clis, mods, effs = {}, {}, {}
        for p in sess:
            for ev in _json_lines(p.read_text(errors="replace")):
                pl = ev.get("payload") or {}
                if ev.get("type") == "session_meta":
                    clis[pl.get("cli_version")] = clis.get(pl.get("cli_version"), 0) + 1
                elif ev.get("type") == "turn_context":
                    mods[pl.get("model")] = mods.get(pl.get("model"), 0) + 1
                    effs[pl.get("effort")] = effs.get(pl.get("effort"), 0) + 1
        if set(clis) - {cli_version}:
            fails.append(f"session cli_version {clis}")
        if set(mods) - {model}:
            fails.append(f"turn_context models {mods}")
        if set(effs) - {"xhigh"}:
            fails.append(f"turn_context efforts {effs}")
        reviews.append(f"info: {len(sess)} sessions, cli {clis}, models {mods}, efforts {effs}")
    return fails, reviews


def main(argv: list[str]) -> int:
    kind = argv[1]
    if kind == "row":
        path, model, rep = Path(argv[2]), argv[3], int(argv[4])
        hit = [r for r in rows(path) if r.get("model") == model and r.get("rep") == rep]
        row = hit[-1] if hit else None
        cli = ({"claude_cli": "2.1.327", "cli_dir": "cli/claude-2.1.327"} if "fable" in model
               else {"codex_cli": "0.170.0", "cli_dir": "cli/codex-0.170.0"})
        fails, reviews = row_gate(row, model, cli)
    elif kind == "claude":
        fails, reviews = claude_gate(Path(argv[2]), argv[3], argv[4])
    elif kind == "codex":
        fails, reviews = codex_gate(Path(argv[2]), argv[3], argv[4],
                                    Path(argv[5]) if len(argv) > 5 else None)
    else:
        print(__doc__)
        return 2
    for f in fails:
        print("FAIL  ", f)
    for r in reviews:
        print("REVIEW", r)
    print("PASS" if not fails else "FAILED")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
