#!/usr/bin/env python3
"""Fetch-address bounds check (exploratory): BMC of fetch_bounds.sv's
property on a design's final RTL with SBY + bitwuzla.

The design is read as the FPGA and cosim builds read it (no RISCV_FORMAL, so
any formal-only branch is out), except that RISCV_FORMAL_ALTOPS replaces the
M-extension arithmetic with the gate's stand-in formulas, which keeps the
solver off 32-bit multipliers and dividers; data values are free in this
environment anyway, so only divider latency changes. Memories become
flip-flops and every flip-flop starts at zero (Verilator's initial state).

    python3 -B research/v2/fetch_bounds/fetch_bounds.py one NAME RTL_DIR [--depth 30]
    python3 -B research/v2/fetch_bounds/fetch_bounds.py all [--depth 30] [--lanes 6]

Writes results/<NAME>-d<depth>.json (PASS, FAIL with the failing step and
the trace's fetch addresses, or TIMEOUT with the last step proven free of a
counterexample).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
WORK = Path("/home/bench/fetchbounds")
OSS = "/opt/hwe-toolchain/oss-cad-suite/bin"
V2 = REPO / "bench/v2"


def sby_text(rtl: list[Path], depth: int) -> str:
    files = [f.name for f in rtl] + ["fetch_bounds.sv"]
    return "\n".join([
        "[options]", "mode bmc", f"depth {depth}", "",
        "[engines]", "smtbmc bitwuzla", "",
        "[script]",
        "read -formal -D RISCV_FORMAL_ALTOPS " + " ".join(files),
        "prep -top fetch_bounds_top",
        "memory_map", "opt -fast", "setundef -zero -init", "",
        "[files]", *(str(f) for f in rtl), str(HERE / "fetch_bounds.sv"), "",
    ])


def rtl_files(rtl_dir: Path) -> list[Path]:
    srcs = sorted(rtl_dir.glob("*.sv"))
    pkg = rtl_dir / "core_pkg.sv"
    return ([pkg] if pkg in srcs else []) + [p for p in srcs if p != pkg]


def trace_addrs(vcd: Path) -> list[str]:
    """io_imemAddr of the top's uut per time step from the counterexample."""
    code, vals, t, out = None, {}, 0, {}
    for line in vcd.read_text(errors="replace").splitlines():
        if line.startswith("$var") and line.split()[4] == "imem_addr" and code is None:
            code = line.split()[3]
        elif line.startswith("#"):
            t = int(line[1:])
        elif code and line.startswith("b") and line.split()[1] == code:
            out[t] = hex(int(line.split()[0][1:], 2))
    return [out[k] for k in sorted(out)]


def one(name: str, rtl_dir: Path, depth: int, timeout: int = 10800) -> dict:
    work = WORK / f"{name}-d{depth}"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    (work / "fb.sby").write_text(sby_text(rtl_files(rtl_dir), depth))
    env = {**os.environ, "PATH": f"{OSS}:{os.environ['PATH']}"}
    t0 = time.time()
    p = subprocess.Popen(["nice", "-n", "15", "sby", "-f", "fb.sby"], cwd=work, env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                         start_new_session=True)
    try:
        out, _ = p.communicate(timeout=timeout)
        timed_out = False
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        out, _ = p.communicate()
        timed_out = True
    rec = {"design": name, "rtl_dir": str(rtl_dir), "depth": depth, "seconds": round(time.time() - t0)}
    if timed_out:
        rec["outcome"] = "TIMEOUT"
        log = work / "fb/logfile.txt"
        st = re.findall(r"Checking assertions in step (\d+)", log.read_text(errors="replace")) if log.exists() else []
        # Steps before the one in progress have no counterexample.
        rec["no_cex_through_step"] = int(st[-1]) - 1 if st else None
    elif "DONE (PASS" in out:
        rec["outcome"] = "PASS"
    elif "DONE (FAIL" in out:
        rec["outcome"] = "FAIL"
        m = re.search(r"Assert failed in fetch_bounds_top.*?\n.*?step (\d+)", out) or \
            re.search(r"BMC failed!.*?\n", out)
        st = re.findall(r"Checking assertions in step (\d+)", out)
        rec["fail_step"] = int(st[-1]) if st else None
        vcd = work / "fb/engine_0/trace.vcd"
        if vcd.exists():
            rec["imem_addr_trace"] = trace_addrs(vcd)
    else:
        rec["outcome"] = "ERROR"
        rec["tail"] = out[-2000:]
    (HERE / "results").mkdir(exist_ok=True)
    (HERE / "results" / f"{name}-d{depth}.json").write_text(json.dumps(rec, indent=1) + "\n")
    print(name, rec["outcome"], rec.get("fail_step", ""), rec["seconds"], "s", flush=True)
    return rec


def designs() -> list[tuple[str, Path]]:
    out = []
    for f in sorted(V2.glob("*/rep*/final-rtl")):
        model, rep = f.parts[-3], f.parts[-2]
        if model.startswith(("random-mutation", "smoke")):
            continue
        out.append((f"{model}_{rep}", f))
    out.append(("textbook", REPO / "research/v2/textbook_baseline/rtl"))
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["one", "all"])
    ap.add_argument("name", nargs="?")
    ap.add_argument("rtl_dir", nargs="?", type=Path)
    ap.add_argument("--depth", type=int, default=30)
    ap.add_argument("--lanes", type=int, default=6)
    ap.add_argument("--timeout", type=int, default=10800)
    a = ap.parse_args()
    if a.cmd == "one":
        d = a.rtl_dir if a.rtl_dir.is_absolute() else REPO / a.rtl_dir
        one(a.name, d, a.depth, a.timeout)
    else:
        todo = [(n, d) for n, d in designs()
                if not (HERE / "results" / f"{n}-d{a.depth}.json").exists()]
        print(len(todo), "designs", flush=True)
        with ThreadPoolExecutor(max_workers=a.lanes) as ex:
            list(ex.map(lambda nd: one(nd[0], nd[1], a.depth, a.timeout), todo))
