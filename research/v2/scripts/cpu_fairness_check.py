"""Check that concurrent bench runs get equal CPU however many threads they
spawn, and that the harness keeps priority (setup_server.sh, 6d).

Run as the operator on the run host with the agent pool idle:
    python3 research/v2/scripts/cpu_fairness_check.py

Phase 1: the three agent accounts spin 20, 20 and 2 threads through the
launch helper; each slice's CPU time comes from its cgroup. Expected: the
2-thread run gets its 2 cores, the two 20-thread runs split the rest evenly.
Phase 2: the same plus 20 spinning operator threads (the harness's
user.slice); the agents together should get about 20/(100+20) of the
machine.
"""
import os
import subprocess
import sys
import time
from pathlib import Path

HELPER = "/usr/local/sbin/hwe-agent-scope"
CG = Path("/sys/fs/cgroup/hweagents.slice")
SPIN = ("import os,sys,time\n"
        "n,s=int(sys.argv[1]),float(sys.argv[2]); d=time.time()+s\n"
        "for _ in range(n):\n"
        "    if os.fork()==0:\n"
        "        while time.time()<d: pass\n"
        "        os._exit(0)\n"
        "for _ in range(n): os.wait()\n")
LOAD = {"hwebench": 20, "hwebench2": 20, "hwebench3": 2}
SECS, WARM, WINDOW = 25, 5, 15


def usage(acct: str) -> int:
    for line in (CG / f"hweagents-{acct}.slice" / "cpu.stat").read_text().splitlines():
        if line.startswith("usage_usec"):
            return int(line.split()[1])
    raise RuntimeError(acct)


def phase(with_harness: bool) -> dict:
    procs = [subprocess.Popen(["sudo", "-n", HELPER, a, "/usr/bin/python3", "-c", SPIN, str(n), str(SECS)])
             for a, n in LOAD.items()]
    if with_harness:
        procs.append(subprocess.Popen([sys.executable, "-c", SPIN, "20", str(SECS)]))
    time.sleep(WARM)
    t0, u0 = time.time(), {a: usage(a) for a in LOAD}
    time.sleep(WINDOW)
    t1, u1 = time.time(), {a: usage(a) for a in LOAD}
    for p in procs:
        p.wait()
    return {a: (u1[a] - u0[a]) / 1e6 / (t1 - t0) for a in LOAD}


def main() -> int:
    ncpu = os.cpu_count()
    ok = True
    p1 = phase(False)
    print(f"phase 1 (agents only, {ncpu} cores): " + ", ".join(f"{a} {c:.1f}" for a, c in p1.items()))
    big = [p1["hwebench"], p1["hwebench2"]]
    # One window's split jitters by about +-10% and the larger share
    # alternates between accounts from trial to trial (measured 2026-09-28,
    # 8.1/9.9, 9.5/8.5, 8.6/9.4, 9.4/8.6 over 30 s), so allow 25% per window.
    if abs(big[0] - big[1]) > 0.25 * max(big):
        print("FAIL: the two 20-thread runs did not split evenly"); ok = False
    if p1["hwebench3"] < 1.6:
        print("FAIL: the 2-thread run did not get its 2 cores"); ok = False
    p2 = phase(True)
    total = sum(p2.values())
    print(f"phase 2 (plus 20 harness threads): " + ", ".join(f"{a} {c:.1f}" for a, c in p2.items())
          + f"; agents total {total:.1f} of {ncpu}")
    if total > 0.3 * ncpu:
        print("FAIL: the harness did not keep priority over the agents"); ok = False
    print("OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
