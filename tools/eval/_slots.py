"""Host-wide slots for the harness's heavy evals (formal, Gowin builds).

Three concurrent runs, each evaluating up to three slots, plus the agents'
own self-checks, saturated the 20-core run host (load 20); formal checks then
hit their wall-clock ceiling because of what other runs were doing, not
because of the design (V2.1 campaign, first batch). With HARNESS_EVAL_SLOTS
set, each eval holds one of that many flock'ed slots (in HARNESS_EVAL_LOCK_DIR,
operator-only) for its duration, and its timeout starts once it holds one.
Unset (agents' own `make timing`, tests): no limit. The variables use a prefix
the agent environment does not inherit (tools/agents/_runtime.py)."""
from __future__ import annotations

import contextlib
import fcntl
import os
import time
from pathlib import Path


@contextlib.contextmanager
def eval_slot(what: str = "eval"):
    n = int(os.environ.get("HARNESS_EVAL_SLOTS", "0") or 0)
    lock_dir = os.environ.get("HARNESS_EVAL_LOCK_DIR", "")
    if n <= 0 or not lock_dir:
        yield
        return
    d = Path(lock_dir)
    d.mkdir(parents=True, exist_ok=True)
    started, told = time.time(), False
    while True:
        for i in range(n):
            f = open(d / f"slot{i}.lock", "w")
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                f.close()
                continue
            waited = time.time() - started
            if waited > 60:
                print(f"  [eval] {what}: got host eval slot {i} after {waited:.0f}s", flush=True)
            try:
                yield
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)
                f.close()
            return
        if not told:
            print(f"  [eval] {what}: waiting for a host eval slot ({n} busy)", flush=True)
            told = True
        time.sleep(5)


def eval_jobs(default: str | None = None) -> str | None:
    """make -j for a formal run holding a slot (HARNESS_EVAL_JOBS)."""
    return os.environ.get("HARNESS_EVAL_JOBS") or default
