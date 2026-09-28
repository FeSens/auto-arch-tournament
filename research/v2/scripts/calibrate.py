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
    # k unused wires; valid for any k (the final measurement uses k > 100).
    body = "".join(f"  wire w{i} = a[{i % 32}] ^ a[{(i + 1) % 32}];\n" for i in range(k))
    return ("module zz_calib_pad(input logic [31:0] a, output logic [31:0] y);\n"
            f"{body}  assign y = a;\nendmodule\n")


FLOW = ""   # synth_gowin options (--flow); "" = the harness's flow


def run_variant(name: str, rtl: str, k: int, out: Path, work_root: Path) -> None:
    tag = re.sub(r"[^A-Za-z0-9]", "", FLOW)
    work = work_root / f"{name}_k{k}{tag}"
    src = work_root / f"{name}_k{k}{tag}_rtl"
    shutil.rmtree(src, ignore_errors=True)
    shutil.copytree(rtl, src)
    if k:
        (src / "zz_calib_pad.sv").write_text(pad_module(k))
    seeds = SEEDS.get(k, DEFAULT_SEEDS)
    import os
    r = subprocess.run(["bash", str(HERE / "wrapper_compare.sh"), str(src), "v2", str(work),
                        *map(str, seeds)], capture_output=True, text=True,
                       env={**os.environ, "SYNTH_ARGS": FLOW})
    rows = []
    for line in r.stdout.splitlines():
        m = LINE.search(line)
        if not m:
            continue
        cells = dict(kv.split("=") for kv in m.group(3).split())
        fmax = None if m.group(2) == "FAILED" else float(m.group(2).split()[0])
        rows.append({"design": name, "k": k, "seed": int(m.group(1)), "fmax_mhz": fmax,
                     **({"flow": FLOW} if FLOW else {}),
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
    print(f"{name} k={k} flow='{FLOW}': " + ", ".join(str(x.get('fmax_mhz')) for x in rows), flush=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("designs", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("work_root", type=Path)
    ap.add_argument("--lanes", type=int, default=2)
    ap.add_argument("--flow", default="", help="extra synth_gowin options")
    ap.add_argument("--only", nargs="+", help="design subset")
    ap.add_argument("--seeds", type=int, nargs="+", help="seeds for every k (overrides defaults)")
    ap.add_argument("--ks", type=int, nargs="+", help="perturbations (overrides KS)")
    ap.add_argument("--k0-seeds", type=int, nargs="+", help="seeds for k=0 only")
    a = ap.parse_args()
    global FLOW, SEEDS, DEFAULT_SEEDS, KS
    FLOW = a.flow
    if a.seeds:
        SEEDS, DEFAULT_SEEDS = {}, a.seeds
    if a.k0_seeds:
        SEEDS = {0: a.k0_seeds}
    if a.ks:
        KS = a.ks
    designs = json.loads(a.designs.read_text())
    if a.only:
        designs = {n: designs[n] for n in a.only}
    done = set()
    if a.out.exists():
        for line in a.out.read_text().splitlines():
            row = json.loads(line)
            if "error" not in row and row.get("flow", "") == FLOW:
                done.add((row["design"], row["k"]))
    a.work_root.mkdir(parents=True, exist_ok=True)
    jobs = [(n, p, k) for n, p in designs.items() for k in KS if (n, k) not in done]
    with ThreadPoolExecutor(a.lanes) as pool:
        for f in [pool.submit(run_variant, n, p, k, a.out, a.work_root) for n, p, k in jobs]:
            f.result()


if __name__ == "__main__":
    main()
