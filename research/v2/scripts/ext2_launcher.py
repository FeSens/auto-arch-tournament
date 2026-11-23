#!/usr/bin/env python3
"""Start Fable 5.2 (amendment 17) only after GPT-6.2 Astra and GPT-6.2 Sol finish.

Operator, 2026-11-19: "lets run for the new models Astra 6.2 and Sol 6.2 (and
only after that), run fable 5.2", and: run the Fable smoke only after both
GPT-6.2 systems finish.

1. Wait until every (system, rep) of GPT-6.2 Astra and GPT-6.2 Sol, reps 1-6, has
   a done row with a held-out score in bench/v2/results-g62*.jsonl (the main
   runner's file plus any rerun file). A rep whose latest row is not done is
   reported once as ALERT (its rerun is the operator's job) and the wait goes on.
2. Then wait until no tools.bench.runner process is alive and all three agent
   accounts are idle, twice 60 s apart: a runner kills every process of each
   account in its pool when it starts (reset_agent), so starting early would kill
   a live run.
3. Smoke (N=1, K=3, unscored) on hwebench3 into bench/v2/smoke-ext2/. Gates:
   ext2_checks.row_gate and claude_gate. A fail stops here. Review items (a
   difference from the Opus/Sonnet init baseline) stop here until the operator
   writes bench/v2/smoke-ext2/fable52-review-ack.json holding exactly the list of
   review strings, after reviewing them (then restart this launcher).
4. Re-check idle, then start three runners, one per account, two reps each
   (amendment 14's layout): tmux main-f52a/b/c, results
   bench/v2/results-fable52-{a,b,c}.jsonl, logs bench/v2/runner-fable52-{a,b,c}.log.

Run it in tmux (it outlives the operator's session):
  tmux new-session -d -s ext2-launch "cd /home/bench/auto-arch-tournament && \
    python3 research/v2/scripts/ext2_launcher.py"
Log: bench/v2/ext2-launcher.log. A restart skips a smoke that already passed and
does nothing if any Fable runner log already exists.
"""
import datetime as dt
import json
import shlex
import subprocess
import sys
import time
from pathlib import Path

REPO = Path("/home/bench/auto-arch-tournament")
sys.path.insert(0, str(REPO / "research" / "v2" / "scripts"))
import ext2_checks as chk  # noqa: E402

V2 = REPO / "bench" / "v2"
LOG = V2 / "ext2-launcher.log"
SMOKE_DIR = V2 / "smoke-ext2"
REF = "bench-v2.8.4"
PRED = ("gpt-6_2-astra_xhigh-v2", "gpt-6_2-sol_xhigh-v2")
REPS = range(1, 7)
ACCTS = ("hwebench", "hwebench2", "hwebench3")
MODEL = "claude-fable-5_2_xhigh-v2"
API_MODEL = "claude-fable-5-2"
CLI = {"claude_cli": "2.1.327", "cli_dir": "cli/claude-2.1.327"}
SMOKE_ACCT = "hwebench3"
SPLIT = (("a", "hwebench", 1, 2), ("b", "hwebench2", 3, 4), ("c", "hwebench3", 5, 6))
ACK = SMOKE_DIR / "fable52-review-ack.json"


def log(msg: str) -> None:
    line = f"{dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')} {msg}"
    print(line, flush=True)
    with LOG.open("a") as f:
        f.write(line + "\n")


def pred_rows() -> list[dict]:
    out = []
    for p in sorted(V2.glob("results-g62*.jsonl")):
        out += chk.rows(p)
    return out


def pred_state() -> tuple[list, dict]:
    """(missing (model, rep) without a done+scored row, {(model, rep): latest status})."""
    rs = pred_rows()
    missing, latest = [], {}
    for m in PRED:
        for r in REPS:
            hit = [x for x in rs if x.get("model") == m and x.get("rep") == r]
            if any(x.get("status") == "done" and isinstance(x.get("holdout_geomean_iter_s"), (int, float))
                   for x in hit):
                continue
            missing.append((m, r))
            if hit:
                latest[(m, r)] = hit[-1].get("status")
    return missing, latest


def runners_alive() -> bool:
    out = subprocess.run(["pgrep", "-af", "python"], capture_output=True, text=True).stdout
    return any(" -m tools.bench.runner " in f" {line.split(None, 1)[-1]} "
               and line.split(None, 1)[-1].startswith("python") for line in out.splitlines())


def accounts_idle() -> bool:
    return all(subprocess.run(["pgrep", "-u", a], capture_output=True).returncode == 1 for a in ACCTS)


def host_idle() -> bool:
    if runners_alive() or not accounts_idle():
        return False
    time.sleep(60)
    return not runners_alive() and accounts_idle()


def runner_cmd(acct: str, first: int, last: int, n: int, results: Path, rdir: Path) -> list[str]:
    return ["python3", "-m", "tools.bench.runner", "--models", "tools/bench/models-v2.yaml",
            "--ref", REF, "--agent-user", acct, "--only", MODEL, "--first-rep", str(first),
            "--reps", str(last), "--n", str(n), "--k", "3", "--results-jsonl", str(results),
            "--results-dir", str(rdir)]


def smoke() -> bool:
    SMOKE_DIR.mkdir(parents=True, exist_ok=True)
    results = SMOKE_DIR / "results-smoke-fable52.jsonl"
    slog = SMOKE_DIR / "runner-smoke-fable52.log"
    hit = [r for r in chk.rows(results) if r.get("model") == MODEL and r.get("rep") == 1]
    if not (hit and hit[-1].get("status") == "done"):
        cmd = runner_cmd(SMOKE_ACCT, 1, 1, 1, results, SMOKE_DIR)
        log(f"fable52: smoke (N=1, K=3) on {SMOKE_ACCT}: {shlex.join(cmd)}")
        with slog.open("a") as f:
            rc = subprocess.run(cmd, cwd=REPO, stdout=f, stderr=subprocess.STDOUT).returncode
        log(f"fable52: smoke runner exit {rc}")
        hit = [r for r in chk.rows(results) if r.get("model") == MODEL and r.get("rep") == 1]
    row = hit[-1] if hit else None
    fails, reviews = chk.row_gate(row, MODEL, CLI)
    f2, r2 = chk.claude_gate(SMOKE_DIR / MODEL / "rep1", API_MODEL, CLI["claude_cli"])
    fails += f2
    reviews += [r for r in r2 if not r.startswith("info:")]
    for r in r2:
        if r.startswith("info:"):
            log(f"fable52: smoke {r}")
    if "git bundle failed" in (slog.read_text(errors="replace") if slog.exists() else ""):
        fails.append("'git bundle failed' in the smoke runner log")
    if fails:
        log(f"ALERT fable52: smoke failed its gates {fails}; not starting the real runs")
        return False
    if reviews:
        acked = json.loads(ACK.read_text()) if ACK.exists() else None
        if acked != reviews:
            log(f"ALERT fable52: smoke passed its gates but needs review {reviews}; write that "
                f"exact list to {ACK} after reviewing it, then restart the launcher")
            return False
        log(f"fable52: review items acknowledged in {ACK.name}")
    log(f"fable52: smoke passed (CoreMark {row.get('final_fitness')}, held-out "
        f"{row['holdout_geomean_iter_s']:.1f} iter/s, claude_cli {row.get('claude_cli')})")
    return True


def tmux_has(session: str) -> bool:
    return subprocess.run(["tmux", "has-session", "-t", f"={session}"],
                          capture_output=True).returncode == 0


def main() -> int:
    if any(V2.glob("runner-fable52-*.log")):
        log("fable52: a runner log already exists, already launched; nothing to do")
        return 0
    log(f"ext2 launcher started: {MODEL} after {', '.join(PRED)} reps 1-6")
    alerted = {}
    while True:
        # A transient error (a fork failing with ENOMEM under host memory
        # pressure, 2026-11-21) must not end the wait: the first launcher
        # died silently that way, its traceback lost with its tmux pane.
        try:
            missing, latest = pred_state()
            for k, st in latest.items():
                if alerted.get(k) != st:
                    alerted[k] = st
                    log(f"ALERT {k[0]} rep{k[1]} latest row {st!r} and no done row; it needs a "
                        f"rerun (into a new results-g62-*.jsonl) before Fable can start")
            if not missing and host_idle():
                break
        except OSError as e:
            log(f"ALERT wait loop error, retrying in 60 s: {e!r}")
        time.sleep(60)
    log("fable52: all 12 GPT-6.2 reps done and scored; no runner alive, all accounts idle")
    if not smoke():
        return 1
    if not host_idle():
        log("ALERT fable52: a runner or account became busy after the smoke; not starting")
        return 1
    for tag, acct, first, last in SPLIT:
        session = f"main-f52{tag}"
        if tmux_has(session):
            log(f"ALERT fable52: tmux session {session} already exists; not starting {tag}")
            continue
        results = V2 / f"results-fable52-{tag}.jsonl"
        rlog = V2 / f"runner-fable52-{tag}.log"
        cmd = runner_cmd(acct, first, last, 15, results, V2)
        shell = f"cd {REPO} && {shlex.join(cmd)} 2>&1 | tee -a {rlog}"
        subprocess.run(["tmux", "new-session", "-d", "-s", session, shell], check=True)
        log(f"fable52: launched reps {first}-{last} in tmux {session} on {acct}: {shlex.join(cmd)}")
        time.sleep(5)
    log("ext2 launcher finished")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        import traceback
        log("ALERT launcher crashed:\n" + traceback.format_exc())
        raise
