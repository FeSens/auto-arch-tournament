#!/usr/bin/env python3
"""Placement-noise calibration driver (EXP-2026-09-27-v2-placement-noise).

For each design and each perturbation k (unused padding module with k
assigns; k=0 = unperturbed), runs scripts/wrapper_compare.sh (the harness's
exact relative-path synth + nextpnr invocation) and appends one JSON row per
seed to runs.jsonl. Resumable: (design, k) pairs already present are skipped.

Usage: calibrate.py <designs.json> <out.jsonl> <work_root> [--lanes 2]
designs.json maps design name -> RTL directory.
"""
import argparse
import json
import re
import shutil
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
KS = [0, 5, 9, 13, 17, 21, 25, 29, 33]
SEEDS = {0: list(range(1, 11))}
DEFAULT_SEEDS = [1, 2, 3, 4, 5]
LINE = re.compile(r"seed (\d+): (FAILED|[\d.]+ MHz) (.*)$")
lock = threading.Lock()


def pad_module(k: int) -> str:
    body = "\n".join(f"  assign y[{i}] = a[{i}] ^ a[{(i + 1) % 32}];" for i in range(k))
    return ("module zz_calib_pad(input logic [31:0] a, output logic [31:0] y);\n"
            f"{body}\nendmodule\n")


def run_variant(name: str, rtl: str, k: int, out: Path, work_root: Path) -> None:
    work = work_root / f"{name}_k{k}"
    src = work_root / f"{name}_k{k}_rtl"
    shutil.rmtree(src, ignore_errors=True)
    shutil.copytree(rtl, src)
    if k:
        (src / "zz_calib_pad.sv").write_text(pad_module(k))
    seeds = SEEDS.get(k, DEFAULT_SEEDS)
    r = subprocess.run(["bash", str(HERE / "wrapper_compare.sh"), str(src), "v2", str(work),
                        *map(str, seeds)], capture_output=True, text=True)
    rows = []
    for line in r.stdout.splitlines():
        m = LINE.search(line)
        if not m:
            continue
        cells = dict(kv.split("=") for kv in m.group(3).split())
        fmax = None if m.group(2) == "FAILED" else float(m.group(2).split()[0])
        rows.append({"design": name, "k": k, "seed": int(m.group(1)), "fmax_mhz": fmax,
                     **{c.lower(): (None if v == "NA" else int(v)) for c, v in cells.items()}})
    if len(rows) != len(seeds):
        rows.append({"design": name, "k": k, "error": "missing seeds",
                     "stdout": r.stdout[-500:], "stderr": r.stderr[-500:]})
    with lock:
        with out.open("a") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")
    shutil.rmtree(work, ignore_errors=True)
    shutil.rmtree(src, ignore_errors=True)
    print(f"{name} k={k}: " + ", ".join(str(x.get('fmax_mhz')) for x in rows), flush=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("designs", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("work_root", type=Path)
    ap.add_argument("--lanes", type=int, default=2)
    a = ap.parse_args()
    designs = json.loads(a.designs.read_text())
    done = set()
    if a.out.exists():
        for line in a.out.read_text().splitlines():
            row = json.loads(line)
            if "error" not in row:
                done.add((row["design"], row["k"]))
    a.work_root.mkdir(parents=True, exist_ok=True)
    jobs = [(n, p, k) for n, p in designs.items() for k in KS if (n, k) not in done]
    with ThreadPoolExecutor(a.lanes) as pool:
        for f in [pool.submit(run_variant, n, p, k, a.out, a.work_root) for n, p, k in jobs]:
            f.result()


if __name__ == "__main__":
    main()
