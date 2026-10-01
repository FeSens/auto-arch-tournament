#!/usr/bin/env python3
"""Start the amendment-13 extension runs as the main runners free their accounts.

GPT-6 Astra takes the account that Luna's rep6 frees; Sonnet 5.5 the one
that Opus 5.5's rep6 frees, after a one-round smoke because its CLI dir is
new (amendment 11 did the same for GPT-6.1 Sol's); GPT-5.5 the one GPT-6.1
Sol's rep6 frees (runner B). A system starts only when its predecessor's
rep6 row is `done` and that runner has released the account:
release_agent kills every process of the account (pkill -u), so a runner
started earlier on it would lose its agents. Anything unexpected (a rep6 that
is not done, a smoke that fails a check, a tmux session that already exists)
is logged as ALERT and that system is not started.

Run it in tmux (it outlives the operator's session):
  tmux new-session -d -s ext-launch "cd /home/bench/auto-arch-tournament && \
    python3 research/v2/scripts/extension_launcher.py"
Log: bench/v2/ext-launcher.log. A restart skips a system whose runner log
already exists (it was launched) and a smoke that already passed.
"""
import datetime as dt
import hashlib
import json
import re
import shlex
import subprocess
import threading
import time
from pathlib import Path

REPO = Path("/home/bench/auto-arch-tournament")
V2 = REPO / "bench" / "v2"
RESULTS_A, RUNNER_A_LOG = V2 / "results-opus-luna.jsonl", V2 / "runner-opus-luna.log"
RESULTS_B, RUNNER_B_LOG = V2 / "results-sol61.jsonl", V2 / "runner-sol61.log"
LOG = V2 / "ext-launcher.log"
SMOKE_DIR = V2 / "smoke-ext"
REF = "bench-v2.8.2"
LAST_REP = 6

PLAN = [
    {"after": "gpt-6-luna_xhigh-v2", "model": "gpt-6-astra_xhigh-v2",
     "results": RESULTS_A, "runner_log": RUNNER_A_LOG,
     "tag": "astra", "session": "main-c", "smoke": None},
    {"after": "claude-opus-5_5_xhigh-v2", "model": "claude-sonnet-5-5_xhigh-v2",
     "results": RESULTS_A, "runner_log": RUNNER_A_LOG,
     "tag": "sonnet55", "session": "main-d",
     "smoke": {"claude_cli": "2.1.284", "cli_dir": "cli/claude-2.1.284"}},
    # Operator, 2026-10-01: "GPT-5.5 start when sol fnishes its 6 reps".
    {"after": "gpt-6_1-sol_xhigh-v2", "model": "gpt-5_5_xhigh-v2",
     "results": RESULTS_B, "runner_log": RUNNER_B_LOG,
     "tag": "gpt55", "session": "main-e", "smoke": None},
]

_lock = threading.Lock()


def log(msg: str) -> None:
    line = f"{dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')} {msg}"
    with _lock:
        print(line, flush=True)
        with LOG.open("a") as f:
            f.write(line + "\n")


def rows(path: Path) -> list[dict]:
    if not path.exists():
        return []
    out = []
    for line in path.read_text().splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def last_row(path: Path, model: str, rep: int) -> dict | None:
    hit = [r for r in rows(path) if r.get("model") == model and r.get("rep") == rep]
    return hit[-1] if hit else None


def account_idle(acct: str) -> bool:
    return subprocess.run(["pgrep", "-u", acct], capture_output=True).returncode == 1


def released(row: dict, runner_log: Path) -> bool:
    """The runner printed the run's end, removed its temp base (the last step of
    release_agent) and the account has no process left."""
    slug = f"{row['model']}-rep{row['rep']}"
    tmp = Path("/srv/hwebench/tmp") / hashlib.sha1(slug.encode()).hexdigest()[:8]
    # _finalize's "=== <slug> <status> in <N>s", not the "=== <slug> starting at" line.
    ended = re.search(rf"=== {re.escape(slug)} \w+ in \d+s", runner_log.read_text(errors="replace"))
    return ended and not tmp.exists() and account_idle(row["agent_user"])


def runner_cmd(model: str, acct: str, reps: int, n: int, results: Path, rdir: Path) -> list[str]:
    return ["python3", "-m", "tools.bench.runner", "--models", "tools/bench/models-v2.yaml",
            "--ref", REF, "--agent-user", acct, "--only", model, "--reps", str(reps),
            "--n", str(n), "--k", "3", "--results-jsonl", str(results),
            "--results-dir", str(rdir)]


def tmux_has(session: str) -> bool:
    return subprocess.run(["tmux", "has-session", "-t", session],
                          capture_output=True).returncode == 0


def smoke(p: dict, acct: str) -> bool:
    SMOKE_DIR.mkdir(parents=True, exist_ok=True)
    results = SMOKE_DIR / f"results-smoke-{p['tag']}.jsonl"
    slog = SMOKE_DIR / f"runner-smoke-{p['tag']}.log"
    if not (last_row(results, p["model"], 1) or {}).get("status") == "done":
        cmd = runner_cmd(p["model"], acct, 1, 1, results, SMOKE_DIR)
        log(f"{p['tag']}: smoke (N=1, K=3) on {acct}: {shlex.join(cmd)}")
        with slog.open("a") as f:
            rc = subprocess.run(cmd, cwd=REPO, stdout=f, stderr=subprocess.STDOUT).returncode
        log(f"{p['tag']}: smoke runner exit {rc}")
    r = last_row(results, p["model"], 1) or {}
    want = {"status": "done", "harness_version": "2.8.2", **p["smoke"]}
    bad = {k: r.get(k) for k, v in want.items() if r.get(k) != v}
    if not (r.get("sandbox_probe") or {}).get("ok"):
        bad["sandbox_probe.ok"] = (r.get("sandbox_probe") or {}).get("ok")
    if not isinstance(r.get("holdout_geomean_iter_s"), (int, float)):
        bad["holdout_geomean_iter_s"] = r.get("holdout_geomean_iter_s")
    if bad:
        log(f"ALERT {p['tag']}: smoke failed its checks {bad}; not starting the real runs")
        return False
    log(f"{p['tag']}: smoke passed (CoreMark {r.get('final_fitness')}, held-out "
        f"{r['holdout_geomean_iter_s']:.1f} iter/s, claude_cli {r.get('claude_cli')})")
    return True


def launch(p: dict) -> None:
    rlog = V2 / f"runner-{p['tag']}.log"
    if rlog.exists():
        log(f"{p['tag']}: {rlog.name} exists, already launched; nothing to do")
        return
    log(f"{p['tag']}: waiting for {p['after']} rep{LAST_REP} to finish and free its account")
    while True:
        row = last_row(p["results"], p["after"], LAST_REP)
        if row is not None:
            if row.get("status") != "done":
                log(f"ALERT {p['tag']}: {p['after']} rep{LAST_REP} ended with status "
                    f"{row.get('status')!r}; its rerun comes first, not starting {p['model']}")
                return
            if released(row, p["runner_log"]):
                time.sleep(30)
                if released(row, p["runner_log"]):
                    break
        time.sleep(60)
    acct = row["agent_user"]
    log(f"{p['tag']}: {p['after']} rep{LAST_REP} done ({row.get('final_fitness')}), "
        f"{acct} released and idle")
    if p["smoke"] and not smoke(p, acct):
        return
    if tmux_has(p["session"]):
        log(f"ALERT {p['tag']}: tmux session {p['session']} already exists; not starting")
        return
    results = V2 / f"results-{p['tag']}.jsonl"
    cmd = runner_cmd(p["model"], acct, LAST_REP, 15, results, V2)
    shell = f"cd {REPO} && {shlex.join(cmd)} 2>&1 | tee -a {rlog}"
    subprocess.run(["tmux", "new-session", "-d", "-s", p["session"], shell], check=True)
    log(f"{p['tag']}: launched in tmux {p['session']} on {acct}: {shlex.join(cmd)}")


def main() -> None:
    log("extension launcher started: " + ", ".join(
        f"{p['model']} after {p['after']} rep{LAST_REP}" for p in PLAN))
    threads = [threading.Thread(target=launch, args=(p,), name=p["tag"]) for p in PLAN]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    log("extension launcher finished")


if __name__ == "__main__":
    main()
