#!/usr/bin/env python3
"""Driver for EXP-2026-09-28-v2-gowin-calibration (see its prereg.yaml).
Usage: gowin_calibrate.py <designs.json> <runs.jsonl> <work_root> [--lanes 9]"""
import argparse, asyncio, json, shutil, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from tools.eval import gowin  # noqa: E402

REPO = Path(__file__).resolve().parents[3]


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("designs"); ap.add_argument("out"); ap.add_argument("work")
    ap.add_argument("--lanes", type=int, default=9)
    a = ap.parse_args()
    designs = json.loads(Path(a.designs).read_text())
    sem = asyncio.Semaphore(a.lanes)
    jobs = [(d, p, tag) for d in designs for p, tag in ((0, "a"), (1, "a"), (2, "a"), (0, "repeat"))]

    async def one(d, p, tag):
        async with sem:
            out = Path(a.work) / f"{d}_p{p}_{tag}"
            r = await asyncio.to_thread(gowin.build, REPO, REPO / designs[d], "fpga/core_bench_si.sv", p, out)
        row = {"design": d, "place_option": p, "run": tag,
               **{k: r.get(k) for k in ("fmax_mhz", "levels", "logic", "regs", "lutram",
                                         "bsram", "dsp", "placement_failed", "reason")}}
        with open(a.out, "a") as f:
            f.write(json.dumps(row) + "\n")
        shutil.rmtree(out, ignore_errors=True)
        print(d, p, tag, r.get("fmax_mhz"), r.get("reason") or "", flush=True)
    await asyncio.gather(*(one(*j) for j in jobs))


asyncio.run(main())
