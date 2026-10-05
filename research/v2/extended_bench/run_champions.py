"""Run the extended suite (build_elfs.py) on every finished V2 champion.

Each champion's saved final RTL (bench/v2/<model>/rep<N>/final-rtl) is built
exactly like the harness's held-out scoring builds it: test/cosim/build.sh's
verilator command (-Wall -Wno-fatal -Wno-style, core_pkg.sv first, NRET=1, the
V2 fixture's retirement width) with the repository's test/cosim/main.cpp, read
in place; the object dir is ~/extbench/sims/<model>-rep<N>. Each ELF runs with
tools/eval/holdout.py's invocation (50M-cycle ceiling, --bench --istall
--dstall), is validated the same way (ebreak, no oob, both markers, the
"HOLDOUT <k> reps=<R> status=PASS" line), and scores
Fmax x 1e6 x reps / bracketed cycles with the run's held-out Fmax (the
re-measured champion Fmax its held-out score used).

Check: for the five held-out kernels the cycle counts must equal the ones in
the run's results row (holdout_kernels); a mismatch is reported per run.

    nice -n 19 python3 -B run_champions.py [--jobs 4] [--ablation]

--ablation runs the amendment 14 no-lessons finals instead
(results-sol61nl-*.jsonl) and writes results/ablation_champions.json.
"""
import json
import math
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path("/home/bench/auto-arch-tournament")
HERE = Path(__file__).resolve().parent
ELFS = Path.home() / "extbench/elfs"
SIMS = Path.home() / "extbench/sims"
RESULTS = ["results.jsonl", "results-opus-luna.jsonl", "results-sol61.jsonl", "results-astra.jsonl",
           "results-sonnet55.jsonl", "results-gpt55.jsonl"]
ABLATION = ["results-sol61nl-a.jsonl", "results-sol61nl-b.jsonl", "results-sol61nl-c.jsonl"]
RESCORED = REPO / "research/runs/EXP-2026-09-28-v2-main/incident_08/holdout_rescored.jsonl"
STATUS = re.compile(r"HOLDOUT\s+(\S+)\s+reps=(\d+)\s+status=(PASS|FAIL)")
ENV = {**os.environ, "PATH": "/opt/hwe-toolchain/oss-cad-suite/bin:" + os.environ["PATH"]}


def runs(files: list[str] = RESULTS) -> list[dict]:
    """Finished runs (a later results file's row wins), with incident 08's
    rescored held-out numbers where the runner had none."""
    done = {}
    for f in files:
        for line in (REPO / "bench/v2" / f).read_text().splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("status") == "done":
                done[(r["model"], r["rep"])] = r
    for line in RESCORED.read_text().splitlines():
        fix = json.loads(line)
        r = done.get((fix["model"], fix["rep"]))
        if r and r.get("started_at") == fix.get("attempt_started_at") and not r.get("holdout_geomean_iter_s"):
            r.update({k: fix[k] for k in ("holdout_geomean_iter_s", "holdout_fmax_mhz", "holdout_kernels")})
    return sorted(done.values(), key=lambda r: (r["model"], r["rep"]))


def build(r: dict) -> Path:
    rtl = REPO / "bench/v2" / r["model"] / f"rep{r['rep']}" / "final-rtl"
    obj = SIMS / f"{r['model']}-rep{r['rep']}"
    sim = obj / "cosim_sim"
    if sim.exists():
        return sim
    files = ([rtl / "core_pkg.sv"] if (rtl / "core_pkg.sv").exists() else []) + \
        [f for f in sorted(rtl.glob("*.sv")) if f.name != "core_pkg.sv"]
    obj.mkdir(parents=True, exist_ok=True)
    cmd = ["verilator", "--cc", "--exe", "--build", "-Mdir", str(obj), f"+incdir+{rtl}",
           "--top-module", "core", "-Wall", "-Wno-fatal", "-Wno-style", "-CFLAGS", "-DNRET=1",
           *map(str, files), str(REPO / "test/cosim/main.cpp"), "-o", "cosim_sim"]
    p = subprocess.run(cmd, capture_output=True, text=True, env=ENV)
    (obj / "build.log").write_text(p.stdout[-20000:] + p.stderr[-20000:])
    if p.returncode != 0 or not sim.exists():
        raise RuntimeError(f"build failed for {obj.name}")
    return sim


def run_elf(sim: Path, elf: Path) -> dict:
    k = elf.stem
    try:
        p = subprocess.run([str(sim), str(elf), "50000000", "--bench", "--istall", "--dstall"],
                           capture_output=True, text=True, timeout=900)
        m = json.loads([l for l in p.stdout.splitlines() if l.strip()][-1])
    except Exception as e:   # noqa: BLE001
        return {"valid": False, "reason": f"harness_error: {e}"}
    if not m.get("ebreak"):
        return {"valid": False, "correct": False, "reason": "maxcycles_hit_before_ebreak"}
    if not m.get("bench_bracketed"):
        return {"valid": False, "correct": False, "reason": "markers_missing"}
    s = STATUS.search(m.get("uart", ""))
    if not (s and s.group(1) == k and s.group(3) == "PASS"):
        return {"valid": False, "correct": False, "reason": "uart_status_missing_or_fail"}
    # "valid" is the harness's rule (an out-of-range access fails the kernel,
    # CLAUDE.md invariant 6); "correct" is a correct result with the timing
    # markers, out-of-range access or not.
    res = {"valid": not m.get("oob"), "correct": True, "oob": bool(m.get("oob")),
           "cycles": m["bench_stop_cycle"] - m["bench_start_cycle"], "reps": int(s.group(2))}
    if m.get("oob"):
        res["reason"] = "oob"
    return res


def one(r: dict) -> dict:
    name = f"{r['model']} rep{r['rep']}"
    out = {"model": r["model"], "rep": r["rep"], "fmax_mhz": r["holdout_fmax_mhz"],
           "holdout_geomean_iter_s": r["holdout_geomean_iter_s"], "kernels": {}, "check": {}}
    try:
        sim = build(r)
    except RuntimeError as e:
        out["error"] = str(e)
        return out
    for elf in sorted(ELFS.glob("*.elf")):
        k = elf.stem
        res = run_elf(sim, elf)
        if res["correct"]:
            res["iter_s"] = r["holdout_fmax_mhz"] * 1e6 * res["reps"] / res["cycles"]
        out["kernels"][k] = res
        scored = (r.get("holdout_kernels") or {}).get(k)
        if scored:
            out["check"][k] = {"scored_cycles": scored["cycles"], "cycles": res.get("cycles"),
                               "match": scored["cycles"] == res.get("cycles")}
    print(name, "kernels valid", sum(v["valid"] for v in out["kernels"].values()), "/", len(out["kernels"]),
          "| held-out cycles match", sum(c["match"] for c in out["check"].values()), "/", len(out["check"]),
          flush=True)
    return out


def main(argv):
    jobs = int(argv[argv.index("--jobs") + 1]) if "--jobs" in argv else 4
    abl = "--ablation" in argv
    rs = runs(ABLATION if abl else RESULTS)
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        res = list(ex.map(one, rs))
    (HERE / "results").mkdir(exist_ok=True)
    out = "results/ablation_champions.json" if abl else "results/champions.json"
    (HERE / out).write_text(json.dumps(res, indent=1))
    bad = [f"{r['model']} rep{r['rep']}" for r in res
           if r.get("error") or not all(c["match"] for c in r["check"].values())]
    print("runs", len(res), "| build errors or held-out mismatches:", bad or "none")


if __name__ == "__main__":
    main(sys.argv[1:])
