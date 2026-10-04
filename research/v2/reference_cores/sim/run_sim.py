"""Stage 2: measured CoreMark and held-out scores for a reference core.

Runs ~/refcores/sim/<core>/Vref_top (sim/build.sh) on the bench's CoreMark ELF
and the five held-out kernel ELFs with --istall --dstall and a 50M-cycle
ceiling, validates each run the way the harness does (validate_coremark_uart
from tools/eval/fpga.py, imported read-only; the held-out UART status line),
and scores with the core's stage 1 Fmax:

  CoreMark  = Fmax x 1e6 x iterations / bracketed cycles   (tools/eval/fpga.py)
  held-out  = geomean over kernels of Fmax x 1e6 x reps / bracketed cycles
              (tools/eval/holdout.py)

ELFs: ~/refcores/elfs (copies of the clone-built coremark.elf, identical code
and data to the main checkout's, and bench/holdout/build/*.elf, the ELFs the
held-out scoring uses).

    nice -n 19 python3 -B run_sim.py <core> [--reset-pc HEX]
"""
import json
import math
import re
import subprocess
import sys
from pathlib import Path

REPO = Path("/home/bench/auto-arch-tournament")
sys.path.insert(0, str(REPO))
from tools.eval.fpga import validate_coremark_uart  # noqa: E402

HERE = Path(__file__).resolve().parent
RC = Path.home() / "refcores"
ELFS = RC / "elfs"
KERNELS = ("dhrystone", "aha-mont64", "crc32", "matmult-int", "edn")
ITERATIONS = 10   # bench/programs/coremark portme.h
STATUS = re.compile(r'HOLDOUT\s+(\S+)\s+reps=(\d+)\s+status=(PASS|FAIL)')


def sim(core: str, elf: Path, extra: list) -> dict:
    p = subprocess.run([str(RC / "sim" / core / "Vref_top"), str(elf), "50000000",
                        "--istall", "--dstall", *extra],
                       capture_output=True, text=True, timeout=1800)
    lines = [l for l in p.stdout.splitlines() if l.strip()]
    return json.loads(lines[-1]) if lines else {"ebreak": False, "uart": "", "error": p.stderr[-500:]}


def check(m: dict) -> str | None:
    if not m.get("ebreak"):
        return "maxcycles_hit_before_ebreak"
    if m.get("oob"):
        return "oob"
    if not m.get("bench_bracketed"):
        return "markers_missing"
    if m["bench_stop_cycle"] <= m["bench_start_cycle"]:
        return "bad_bracket"
    return None


def main(core: str, extra: list) -> dict:
    stage1 = json.loads((HERE.parent / "references.json").read_text())
    ref = next(r for r in stage1 if r["key"] == core)
    fmax = json.loads((REPO / ref["result"]).read_text())["summary"]["fmax_mhz"]

    out = {"core": core, "fmax_mhz": fmax, "sim_args": extra}
    m = sim(core, ELFS / "coremark.elf", extra)
    err = check(m)
    if not err:
        ok, reason = validate_coremark_uart(m["uart"], ITERATIONS)
        err = None if ok else reason
    cyc = m.get("bench_stop_cycle", 0) - m.get("bench_start_cycle", 0)
    out["coremark"] = {"valid": err is None, "reason": err, "cycles": cyc, "end": m.get("end"),
                       "coremark_per_mhz": ITERATIONS / cyc * 1e6 if err is None else 0.0,
                       "score": fmax * ITERATIONS / cyc * 1e6 if err is None else 0.0}
    ks = {}
    for k in KERNELS:
        m = sim(core, ELFS / f"{k}.elf", extra)
        err = check(m)
        s = STATUS.search(m.get("uart", ""))
        if not err and not (s and s.group(1) == k and s.group(3) == "PASS"):
            err = "uart_status_missing_or_fail"
        cyc = m.get("bench_stop_cycle", 0) - m.get("bench_start_cycle", 0)
        reps = int(s.group(2)) if s else 0
        ks[k] = {"valid": err is None, "reason": err, "cycles": cyc, "reps": reps, "end": m.get("end"),
                 "iter_s": fmax * 1e6 * reps / cyc if err is None else 0.0}
    out["holdout"] = ks
    good = [v["iter_s"] for v in ks.values() if v["valid"]]
    out["holdout_geomean_iter_s"] = math.exp(sum(map(math.log, good)) / len(good)) \
        if len(good) == len(KERNELS) else 0.0
    res = HERE.parent / "results_sim"
    res.mkdir(exist_ok=True)
    (res / f"{core}.json").write_text(json.dumps(out, indent=1))
    return out


if __name__ == "__main__":
    o = main(sys.argv[1], sys.argv[2:])
    print(o["core"], "fmax", o["fmax_mhz"], "| CoreMark", json.dumps(o["coremark"]),
          "| held-out geomean", round(o["holdout_geomean_iter_s"], 1),
          {k: (round(v["iter_s"], 1) if v["valid"] else v["reason"]) for k, v in o["holdout"].items()})
