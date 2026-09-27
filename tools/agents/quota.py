"""Provider quota handling (HWE Bench V2).

When a CLI reports a subscription or rate limit, the attempt it was running
is not a model failure: V1's GPT-6 Astra runs lost 23 slots to a weekly
Codex limit and had to be repaired by hand. Here the agent call waits until
the limit resets and reruns the attempt from scratch with its full time
budget; the pause is logged and never counted against the agent.

Detection reads only the CLIs' structured error events, never the agent's
own prose (an agent writing about "rate limits" must not trigger a pause):
  - Codex exec --json: {"type": "error"} / {"type": "turn.failed"}
  - Claude Code stream-json: {"type": "result", "is_error": true} and
    {"type": "system"/"assistant"} events carrying an API error
"""
from __future__ import annotations

import datetime as dt
import json
import re
import time
from pathlib import Path
from typing import Callable, Optional

QUOTA_RE = re.compile(
    r"usage limit|hit your (?:usage )?limit|limit reached|usage_limit|rate[_ ]limit|"
    r"quota|too many requests|\b429\b",
    re.I,
)
TRANSIENT_RE = re.compile(r"overloaded|\b529\b|\b503\b|temporarily unavailable", re.I)

POLL_SEC = 20 * 60          # wait between probes when no reset time is given
TRANSIENT_SEC = 3 * 60      # provider overload: short backoff
RESET_SLACK_SEC = 5 * 60    # after a stated reset time
MAX_WAIT_SEC = 10 * 24 * 3600   # give up after 10 days in total (weekly limits)
MAX_TRANSIENT_RETRIES = 10


def _error_texts(lines: list[str]) -> list[str]:
    out = []
    for line in lines:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = ev.get("type")
        if t == "error":
            out.append(str(ev.get("message", "")))
        elif t == "turn.failed":
            out.append(str((ev.get("error") or {}).get("message", "")))
        elif t == "result" and ev.get("is_error"):
            out.append(str(ev.get("result", "")) + " " + str(ev.get("api_error_status", "")))
        elif ev.get("error") and t in ("assistant", "system"):
            out.append(json.dumps(ev.get("error")))
    return out


def classify(lines: list[str]) -> tuple[Optional[str], Optional[dt.datetime]]:
    """Return ('quota' | 'transient' | None, reset time if stated)."""
    for text in reversed(_error_texts(lines)):
        if QUOTA_RE.search(text):
            return "quota", parse_reset(text)
        if TRANSIENT_RE.search(text):
            return "transient", None
    return None, None


_CODEX_AT = re.compile(r"try again at ([A-Z][a-z]{2}) (\d{1,2})(?:st|nd|rd|th)?, (\d{4}) (\d{1,2}):(\d{2}) ?([AP]M)")
_EPOCH = re.compile(r"\|(\d{10})\b")
_MONTHS = {m: i for i, m in enumerate(
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], 1)}


def parse_reset(text: str) -> Optional[dt.datetime]:
    """Reset time as a naive local datetime, if the message states one."""
    m = _CODEX_AT.search(text)
    if m:
        mon, day, year, hh, mm, ampm = m.groups()
        h = int(hh) % 12 + (12 if ampm == "PM" else 0)
        return dt.datetime(int(year), _MONTHS[mon], int(day), h, int(mm))
    m = _EPOCH.search(text)
    if m:
        return dt.datetime.fromtimestamp(int(m.group(1)))
    return None


def wait_seconds(kind: str, reset: Optional[dt.datetime], now: Optional[dt.datetime] = None) -> int:
    if kind == "transient":
        return TRANSIENT_SEC
    now = now or dt.datetime.now()
    if reset is not None:
        return max(60, int((reset - now).total_seconds()) + RESET_SLACK_SEC)
    return POLL_SEC


def run_with_quota_wait(run: Callable[[str], tuple[int, bool]],
                        log_path: Path,
                        reset_attempt: Callable[[], None] = lambda: None,
                        sleep: Callable[[float], None] = time.sleep,
                        initial_mode: str = "w") -> tuple[int, bool]:
    """Call run(mode) until it ends for a reason other than a provider limit.

    run(mode) runs the agent once, writing to log_path with the given file
    mode, and returns (returncode, timed_out). Before each rerun,
    reset_attempt() discards the interrupted attempt's partial work.
    """
    waited = 0
    transient = 0
    mode = initial_mode
    while True:
        start = log_path.stat().st_size if (mode == "a" and log_path.exists()) else 0
        rc, timed_out = run(mode)
        if timed_out:
            return rc, timed_out
        lines = []
        if log_path.exists():  # an agent that wrote nothing reported no limit
            with log_path.open(errors="replace") as f:
                f.seek(start)
                lines = f.read().splitlines()
        kind, reset = classify(lines)
        if kind is None:
            return rc, timed_out
        if kind == "transient":
            transient += 1
            if transient > MAX_TRANSIENT_RETRIES:
                return rc, timed_out
        secs = wait_seconds(kind, reset)
        if waited + secs > MAX_WAIT_SEC:
            return rc, timed_out
        event = {"type": "quota_pause", "kind": kind,
                 "at": dt.datetime.now().isoformat(timespec="seconds"),
                 "reset": reset.isoformat() if reset else None, "sleep_sec": secs}
        with log_path.open("a") as f:
            f.write(json.dumps(event) + "\n")
        print(f"  [quota] {kind}: sleeping {secs}s"
              f"{' until ' + reset.isoformat() if reset else ''}; attempt will rerun from scratch",
              flush=True)
        sleep(secs)
        waited += secs
        reset_attempt()
        mode = "a"
