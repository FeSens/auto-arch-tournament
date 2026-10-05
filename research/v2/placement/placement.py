#!/usr/bin/env python3
"""Placement robustness (exploratory): is the V2 ranking an artifact of the
Gowin settings the score uses?

The scored Fmax is the median over place_option 0, 1, 2 with Gowin's default
router (tools/eval/gowin.py). Options 1 and 2 give identical results on
every design (EXP-2026-09-28-v2-gowin-calibration), and this Gowin version
rejects place_option 3 and 4, so the only other settings that change a build
are the router's: route_option 1 and 2. This driver builds every final design
under place_option {0, 1} x route_option {1, 2} (four new builds; the scored
measurement already has route_option 0 for place 0 and 1), with the harness's
wrapper (fpga/core_bench_si.sv), constraints and Gowin version, through
tools/eval/gowin.build with the route option added to its project script.

    python3 -B research/v2/placement/placement.py run [--lanes 6]
    python3 -B research/v2/placement/placement.py analyze > research/v2/placement/results/analysis.md

`run` appends one row per build to results/builds.jsonl and skips builds
already there.
"""
from __future__ import annotations

import argparse
import itertools
import json
import math
import shutil
import statistics
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "research/v2/scripts"))
from tools.eval import gowin  # noqa: E402
import analyze_main as am  # noqa: E402

HERE = Path(__file__).resolve().parent
OUT = HERE / "results/builds.jsonl"
WORK = Path("/home/bench/placement-work")
V2 = REPO / "bench/v2"
CAMPAIGN = ["results.jsonl", "results-opus-luna.jsonl", "results-sol61.jsonl",
            "results-astra.jsonl", "results-sonnet55.jsonl", "results-gpt55.jsonl"]
ABLATION = ["results-sol61nl-a.jsonl", "results-sol61nl-b.jsonl", "results-sol61nl-c.jsonl"]
RESCORED = REPO / "research/runs/EXP-2026-09-28-v2-main/incident_08/holdout_rescored.jsonl"
NOLESSONS = "gpt-6_1-sol_xhigh-v2-nolessons"
NEW = [(0, 1), (0, 2), (1, 1), (1, 2)]


def scored_runs() -> list[dict]:
    scored, _ = am.load([V2 / f for f in CAMPAIGN], [RESCORED])
    abl, _ = am.load([V2 / f for f in ABLATION])
    rows = [r for (m, _), r in sorted(scored.items()) if m in am.SHORT]
    rows += [r for (m, _), r in sorted(abl.items()) if m == NOLESSONS]
    return rows


def tcl_with_route(route: int):
    def tcl(worktree, rtl_dir, bench_sv, place_option):
        s = gowin.project_tcl(worktree, rtl_dir, bench_sv, place_option)
        return s.replace("set_option -gen_text_timing_rpt 1",
                         f"set_option -route_option {route}\nset_option -gen_text_timing_rpt 1")
    return tcl


def build_one(design: str, rtl: Path, place: int, route: int) -> dict:
    out = WORK / f"{design}_p{place}_r{route}"
    # gowin.build's own steps, with the route option in the project script.
    tcl = tcl_with_route(route)(REPO, rtl, "fpga/core_bench_si.sv", place)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    (out / "build.tcl").write_text(tcl)
    log = out / "gw.log"
    timed_out = gowin._run_gw_sh(out, log, gowin.gowin_env(None, out))
    res = ({"placement_failed": True, "fmax_mhz": None, "reason": "timeout"} if timed_out
           else gowin.parse_reports(out))
    row = {"design": design, "place_option": place, "route_option": route,
           **{k: res.get(k) for k in ("fmax_mhz", "levels", "logic", "regs", "placement_failed", "reason")}}
    shutil.rmtree(out, ignore_errors=True)
    return row


def run(lanes: int) -> None:
    done = set()
    if OUT.exists():
        for l in OUT.read_text().splitlines():
            r = json.loads(l)
            done.add((r["design"], r["place_option"], r["route_option"]))
    jobs = []
    for r in scored_runs():
        design = f"{r['model']}_rep{r['rep']}"
        rtl = V2 / r["model"] / f"rep{r['rep']}" / "final-rtl"
        for p, rt in NEW:
            if (design, p, rt) not in done:
                jobs.append((design, rtl, p, rt))
    for d, rtl in (("v0", None), ("textbook", REPO / "research/v2/textbook_baseline/rtl")):
        if rtl is None:
            rtl = WORK / "v0-rtl"
            if not rtl.exists():
                rtl.mkdir(parents=True)
                import subprocess
                arc = subprocess.run(["git", "-C", str(REPO), "archive", "hwe-bench-v2.8.4", "cores/bench/rtl"],
                                     check=True, capture_output=True).stdout
                subprocess.run(["tar", "-x", "-C", str(rtl), "--strip-components=3"], input=arc, check=True)
        for p, rt in [(0, 0), (1, 0), *NEW]:
            if (d, p, rt) not in done:
                jobs.append((d, rtl, p, rt))
    print(f"{len(jobs)} builds to run", flush=True)
    OUT.parent.mkdir(exist_ok=True)

    def one(j):
        row = build_one(*j)
        with open(OUT, "a") as f:
            f.write(json.dumps(row) + "\n")
        print(row["design"], row["place_option"], row["route_option"], row["fmax_mhz"], flush=True)

    with ThreadPoolExecutor(max_workers=lanes) as ex:
        list(ex.map(one, jobs))


def analyze() -> None:
    builds = {}
    for l in OUT.read_text().splitlines():
        r = json.loads(l)
        builds[(r["design"], r["place_option"], r["route_option"])] = r
    runs = scored_runs()
    per = []
    for r in runs:
        d = f"{r['model']}_rep{r['rep']}"
        pairs = {p: f for p, f, _ in r["holdout_fmax_pairs"]}
        f = {(0, 0): pairs[0], (1, 0): pairs[1]}
        for p, rt in NEW:
            b = builds.get((d, p, rt))
            assert b and not b["placement_failed"], (d, p, rt)
            f[(p, rt)] = b["fmax_mhz"]
        per.append({"model": r["model"], "rep": r["rep"], "scored_fmax": r["holdout_fmax_mhz"],
                    "heldout": r["holdout_geomean_iter_s"], "fmax": f})
    settings = [(0, 0), (1, 0), *NEW]
    views = {"scored (median of p0, p1, p2 with route 0)": lambda x: x["scored_fmax"],
             "median of all six settings": lambda x: statistics.median(x["fmax"].values()),
             "best of six": lambda x: max(x["fmax"].values()),
             "worst of six": lambda x: min(x["fmax"].values())}
    for s in settings:
        views[f"place {s[0]}, route {s[1]} alone"] = (lambda s: lambda x: x["fmax"][s])(s)
    print("# Placement robustness (exploratory)\n")
    print("Held-out score = Fmax x the run's held-out cycle geomean (cycles do not depend on placement), "
          "so each view rescales each run's score by its Fmax under that view.\n")
    sd = [statistics.stdev(math.log(v) for v in x["fmax"].values()) for x in per]
    print(f"Per design, SD of ln Fmax over the six settings: median {statistics.median(sd):.3f}, "
          f"max {max(sd):.3f} ({len(per)} designs).\n")
    print("| view | primary Opus/Sol ratio [95% CI], p | extension pairs separating (of 12) | "
          "system order (held-out geomean) | Kendall tau vs scored |")
    print("|---|---|---|---|---|")
    base_order = None
    base_seps = None
    out = {}
    for name, fn in views.items():
        ln = {m: [math.log(x["heldout"] * fn(x) / x["scored_fmax"]) for x in per if x["model"] == m]
              for m in am.SHORT}
        gm = {m: math.exp(statistics.fmean(v)) for m, v in ln.items()}
        order = sorted(gm, key=gm.get, reverse=True)
        a, b = am.PRIMARY
        prim = am.welch(ln[a], ln[b])
        ext = [(x, y) for x, y in itertools.combinations(am.SHORT, 2)
               if (x in am.ADDED or y in am.ADDED)]
        res = [am.welch(ln[x], ln[y]) for x, y in ext]
        adj = am.holm([t["p"] for t in res])
        seps = [f"{am.SHORT[x]}/{am.SHORT[y]}" for (x, y), t, p in zip(ext, res, adj)
                if p < am.ALPHA and (t["ci95"][0] > 1 or t["ci95"][1] < 1)]
        sep = len(seps)
        if base_order is None:
            base_order = order
        tau = _kendall([gm[m] for m in am.SHORT], [math.exp(statistics.fmean(
            [math.log(x["heldout"]) for x in per if x["model"] == m])) for m in am.SHORT])
        if base_seps is None:
            base_seps = seps
        out[name] = {"primary": prim, "ext_separating": seps, "order": [am.SHORT[m] for m in order], "tau": tau}
        print(f"| {name} | {prim['ratio']:.3f} [{prim['ci95'][0]:.3f}, {prim['ci95'][1]:.3f}], "
              f"p = {prim['p']:.4f} | {sep}{'' if seps == base_seps else ' (different set)'} | "
              f"{' > '.join(am.SHORT[m] for m in order)} | {tau:.3f} |")
    ext_all = [f"{am.SHORT[x]}/{am.SHORT[y]}" for x, y in itertools.combinations(am.SHORT, 2)
               if (x in am.ADDED or y in am.ADDED)]
    print(f"\nExtension pairs that separate in the scored view: {', '.join(base_seps)}; "
          f"not separating: {', '.join(p for p in ext_all if p not in base_seps)}.")
    for x in per:
        x["fmax"] = {f"place{p}_route{r}": f for (p, r), f in x["fmax"].items()}
    (HERE / "results/analysis.json").write_text(json.dumps({"per_run": per, "views": out}, indent=1))


def _kendall(x, y):
    n = len(x)
    c = d = 0
    for i in range(n):
        for j in range(i + 1, n):
            s = (x[i] - x[j]) * (y[i] - y[j])
            c += s > 0
            d += s < 0
    return (c - d) / (n * (n - 1) / 2)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["run", "analyze"])
    ap.add_argument("--lanes", type=int, default=6)
    a = ap.parse_args()
    run(a.lanes) if a.cmd == "run" else analyze()
