#!/usr/bin/env python3
"""Pre-registered test of amendment 14: the no-lessons ablation.

GPT-6.1 Sol with the full prompt profile (the six scored campaign runs) vs
GPT-6.1 Sol with the "nolessons" profile (no scribe, so no LESSONS.md), six
runs each. Welch two-sided on ln(held-out score), ratio of geometric means
(full / nolessons) with its 95% CI and the 10,000-sample bootstrap CI, alpha
0.05, a family of its own. Verdict: "scores higher" only when the CI excludes
1 and p < 0.05, otherwise "not distinguishable at n=6".

Descriptive, both arms: CoreMark score, accepted / rejected / broken counts
(broken by first failing gate), Fmax, LUT4, wall time and tokens.

    research/v2/scripts/analyze_ablation.py [--json out.json] > out.md

The control rows are read with analyze_main.load over the campaign's results
files and incident 08's rescored file, so the scored control run of each rep
is the one the main analysis uses. Standard library only.
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from analyze_main import ALPHA, bootstrap_ratio, load, welch  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
V2 = REPO / "bench" / "v2"
CAMPAIGN = ["results.jsonl", "results-opus-luna.jsonl", "results-sol61.jsonl",
            "results-astra.jsonl", "results-sonnet55.jsonl", "results-gpt55.jsonl"]
RESCORED = REPO / "research/runs/EXP-2026-09-28-v2-main/incident_08/holdout_rescored.jsonl"
ABLATION = ["results-sol61nl-a.jsonl", "results-sol61nl-b.jsonl", "results-sol61nl-c.jsonl"]
FULL, NOLESSONS = "gpt-6_1-sol_xhigh-v2", "gpt-6_1-sol_xhigh-v2-nolessons"
NAME = {FULL: "Sol 6.1 (full)", NOLESSONS: "Sol 6.1 (no lessons)"}
N = 6


def arm(model: str) -> list[dict]:
    files = CAMPAIGN if model == FULL else ABLATION
    scored, _ = load([V2 / f for f in files], [RESCORED] if model == FULL else [])
    return [r for (m, _), r in sorted(scored.items(), key=lambda kv: kv[0][1]) if m == model]


def champion_lut4(r: dict) -> int:
    """LUT4 of the final champion: the last accepted entry of the run's log
    (the row's best_lut4 belongs to the highest-fitness slot, accepted or not)."""
    log = V2 / r["model"] / f"rep{r['rep']}" / "log.jsonl"
    acc = [json.loads(l) for l in log.read_text().splitlines()
           if l.strip() and json.loads(l).get("outcome") == "improvement"]
    return int(acc[-1]["lut4"])


def gm(xs: list[float]) -> float:
    return math.exp(statistics.fmean(math.log(x) for x in xs))


def describe(rows: list[dict]) -> dict:
    def col(k):
        return [r[k] for r in rows if r.get(k) is not None]
    broken: dict[str, int] = {}
    for r in rows:
        for k, v in (r.get("broken_by_class") or {}).items():
            broken[k] = broken.get(k, 0) + v
    return {
        "n": len(rows),
        "holdout_geomean": gm(col("holdout_geomean_iter_s")),
        "coremark_geomean": gm(col("final_fitness")),
        "fmax_mean": statistics.fmean(col("holdout_fmax_mhz")),
        "lut4_mean": statistics.fmean(champion_lut4(r) for r in rows),
        # The runner counts the baseline retest as accepted; slots only here.
        "accepted": sum(r["accepted"] - 1 for r in rows),
        "rejected": sum(r["rejected"] for r in rows),
        "broken": sum(r["broken"] for r in rows),
        "broken_by_class": broken,
        "wall_h_mean": statistics.fmean(col("wall_clock_sec")) / 3600,
        "tokens_in_mean": statistics.fmean(col("total_tokens_in")),
        "tokens_out_mean": statistics.fmean(col("total_tokens_out")),
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--json", type=Path, help="also write the numbers here")
    args = ap.parse_args()
    rows = {m: arm(m) for m in (FULL, NOLESSONS)}

    print("# Amendment 14: no-lessons ablation\n")
    print("## Scored runs\n")
    print("| arm | rep | harness | CoreMark | held-out iter/s | Fmax MHz | LUT4 "
          "| accepted / rejected / broken | wall h | tokens in (M) |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for m, rs in rows.items():
        for r in rs:
            print(f"| {NAME[m]} | {r['rep']} | {r.get('harness_version')} | {r['final_fitness']:.1f} "
                  f"| {r['holdout_geomean_iter_s']:.0f} | {r['holdout_fmax_mhz']:.1f} | {champion_lut4(r)} "
                  f"| {r['accepted'] - 1} / {r['rejected']} / {r['broken']} "
                  f"| {r['wall_clock_sec'] / 3600:.1f} | {r['total_tokens_in'] / 1e6:.0f} |")

    out: dict = {"n": {NAME[m]: len(rs) for m, rs in rows.items()},
                 "descriptive": {NAME[m]: describe(rs) for m, rs in rows.items()}}
    print("\n## Arms\n")
    print("| arm | n | geomean held-out | geomean CoreMark | mean Fmax | mean LUT4 "
          "| accepted / rejected / broken (slots) | broken by gate | mean wall h | mean tokens in (M) / out (M) |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for name, d in out["descriptive"].items():
        bb = ", ".join(f"{k} {v}" for k, v in sorted(d["broken_by_class"].items())) or "none"
        print(f"| {name} | {d['n']} | {d['holdout_geomean']:.0f} | {d['coremark_geomean']:.1f} "
              f"| {d['fmax_mean']:.1f} | {d['lut4_mean']:.0f} "
              f"| {d['accepted']} / {d['rejected']} / {d['broken']} | {bb} "
              f"| {d['wall_h_mean']:.1f} | {d['tokens_in_mean'] / 1e6:.0f} / {d['tokens_out_mean'] / 1e6:.2f} |")

    a = [math.log(r["holdout_geomean_iter_s"]) for r in rows[FULL]]
    b = [math.log(r["holdout_geomean_iter_s"]) for r in rows[NOLESSONS]]
    if len(a) != N or len(b) != N:
        print(f"\nTest not run: the pre-registered test needs {N} scored runs per arm "
              f"(full {len(a)}, no lessons {len(b)}).")
    else:
        res = welch(a, b)
        res["boot95"] = bootstrap_ratio(a, b)
        lo, hi = res["ci95"]
        if res["p"] < ALPHA and (lo > 1 or hi < 1):
            hi_arm, lo_arm = (FULL, NOLESSONS) if res["ratio"] > 1 else (NOLESSONS, FULL)
            res["verdict"] = f"{NAME[hi_arm]} scores higher than {NAME[lo_arm]}"
        else:
            res["verdict"] = "not distinguishable at n=6"
        out["test"] = res
        print("\n## Test: full vs no lessons (Welch on ln held-out score)\n")
        print(f"ratio of geometric means (full / no lessons) {res['ratio']:.3f}, "
              f"95% CI [{lo:.3f}, {hi:.3f}], bootstrap 95% CI "
              f"[{res['boot95'][0]:.3f}, {res['boot95'][1]:.3f}]; "
              f"t = {res['t']:.2f}, df = {res['df']:.1f}, p = {res['p']:.4f}")
        print(f"Verdict: {res['verdict']}")
    if args.json:
        args.json.write_text(json.dumps(out, indent=1) + "\n")


if __name__ == "__main__":
    main()
