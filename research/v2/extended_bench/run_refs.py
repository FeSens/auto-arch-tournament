"""Run the extended suite (build_elfs.py) on the reference cores, with their
stage 2 simulators (research/v2/reference_cores/sim, ~/refcores/sim/<core>),
the same stall model and validation as run_champions.py, and their stage 1
Fmax.

    nice -n 19 python3 -B run_refs.py [--jobs 4]
"""
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import run_champions as rc

REPO = rc.REPO
HERE = Path(__file__).resolve().parent
RC = Path.home() / "refcores"
RESET = {"ibex_small": "80", "ibex_maxperf": "80", "vexriscv_nocache": "80000000",
         "vexriscv_maxperf": "80000000"}


def run_ref(ref: dict) -> dict:
    import subprocess, re  # noqa: E401
    key = ref["key"]
    fmax = json.loads((REPO / ref["result"]).read_text())["summary"]["fmax_mhz"]
    sim = RC / "sim" / key / "Vref_top"
    out = {"key": key, "name": ref["name"], "fmax_mhz": fmax, "kernels": {}}
    for elf in sorted(rc.ELFS.glob("*.elf")):
        k = elf.stem
        cmd = [str(sim), str(elf), "50000000", "--istall", "--dstall"] + \
            (["--reset-pc", RESET[key]] if key in RESET else [])
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
        m = json.loads([l for l in p.stdout.splitlines() if l.strip()][-1])
        s = rc.STATUS.search(m.get("uart", ""))
        reason = None if m.get("ebreak") else "maxcycles_hit_before_ebreak"
        reason = reason or (None if m.get("bench_bracketed") else "markers_missing") or \
            (None if s and s.group(1) == k and s.group(3) == "PASS" else "uart_status_missing_or_fail") or \
            ("oob" if m.get("oob") else None)
        correct = reason in (None, "oob")
        res = {"valid": reason is None, "correct": correct, "oob": bool(m.get("oob")), "reason": reason,
               "end": m.get("end")}
        if correct:
            res.update(cycles=m["bench_stop_cycle"] - m["bench_start_cycle"], reps=int(s.group(2)))
            res["iter_s"] = fmax * 1e6 * res["reps"] / res["cycles"]
        out["kernels"][k] = res
    print(key, "kernels valid", sum(v["valid"] for v in out["kernels"].values()), "/", len(out["kernels"]), flush=True)
    return out


def main(argv):
    jobs = int(argv[argv.index("--jobs") + 1]) if "--jobs" in argv else 4
    refs = json.loads((REPO / "research/v2/reference_cores/references.json").read_text())
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        res = list(ex.map(run_ref, refs))
    (HERE / "results").mkdir(exist_ok=True)
    (HERE / "results/references.json").write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    main(sys.argv[1:])
