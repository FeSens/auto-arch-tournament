"""Per-benchmark tables (exploratory): CoreMark and the 20 extended-suite
kernels, one column per system (geomean over its runs) and one per reference
core, with the held-out-5, new-15 and all-20 geomeans.

Agents' CoreMark is the run's final_fitness (the loop's score); the 20
kernels use each run's held-out Fmax (run_champions.py). Reference CoreMark is
the stage 2 measured score (reference_cores/results_sim), the kernels come
from run_refs.py. Rows compare across columns only: reps differ per kernel.

    python3 -B per_benchmark.py > results/per_benchmark_table.md
"""
import json
import math
import statistics
from pathlib import Path

import analyze
import run_champions as rc

HERE = Path(__file__).resolve().parent
SIM = rc.REPO / "research/v2/reference_cores/results_sim"
HELD_OUT = analyze.HELD_OUT


def gm(xs):
    return math.exp(statistics.fmean(map(math.log, xs)))


def fmt(x):
    return f"{x:,.0f}" if x >= 100 else f"{x:.1f}"


def table(cols, rows):
    print("| benchmark | " + " | ".join(cols) + " |")
    print("|---|" + "---|" * len(cols))
    for name, cells in rows:
        print(f"| {name} | " + " | ".join(cells) + " |")
    print()


def main():
    champs = json.loads((HERE / "results/champions.json").read_text())
    refs = json.loads((HERE / "results/references.json").read_text())
    fit = {(r["model"], r["rep"]): r["final_fitness"] for r in rc.runs()}
    kernels = list(HELD_OUT) + sorted(k for k in champs[0]["kernels"] if k not in HELD_OUT)
    new = kernels[len(HELD_OUT):]

    # Per system: geomean over runs of each benchmark (correct results).
    sys_cols, sys_vals = [], []
    for m, name in analyze.NAMES.items():
        cs = [c for c in champs if c["model"] == m]
        if not cs:
            continue
        v = {"CoreMark": gm([fit[(m, c["rep"])] for c in cs])}
        for k in kernels:
            v[k] = gm([c["kernels"][k]["iter_s"] for c in cs])
        v["oob"] = any(x.get("oob") for c in cs for x in c["kernels"].values())
        sys_cols.append(f"{name} (n={len(cs)})")
        sys_vals.append(v)

    ref_cols, ref_vals = [], []
    for r in refs:
        sim = json.loads((SIM / f"{r['key']}.json").read_text())
        v = {"CoreMark": sim["coremark"]["score"]}
        v.update({k: r["kernels"][k]["iter_s"] for k in kernels})
        ref_cols.append((f"{r['name']} ({r['fmax_mhz']:.0f} MHz)", v))
    ref_cols.sort(key=lambda t: -gm([t[1][k] for k in kernels]))

    def rows(vals):
        out = [("CoreMark", [fmt(v["CoreMark"]) for v in vals])]
        out += [(f"{k}{' (held-out)' if k in HELD_OUT else ''}", [fmt(v[k]) for v in vals]) for k in kernels]
        for label, ks in (("held-out 5", HELD_OUT), ("new 15", new), ("all 20", kernels)):
            out.append((f"**geomean {label}**", [f"**{fmt(gm([v[k] for k in ks]))}**" for v in vals]))
        return out

    print("# Per-benchmark scores, iter/s (exploratory, not pre-registered)\n")
    print("Higher is better. Compare within a row: kernels run different rep counts. Model columns "
          "are geomeans over the system's runs (pilot excluded); CoreMark is the loop's score, the "
          "kernels use the run's held-out Fmax. Reference cores run in the stage 2 simulators at "
          "their stage 1 Fmax with the same stall model.\n")
    order = sorted(range(len(sys_vals)), key=lambda i: -gm([sys_vals[i][k] for k in kernels]))
    combined = [(sys_cols[i], gm([sys_vals[i][k] for k in kernels])) for i in order] + \
        [(c, gm([v[k] for k in kernels])) for c, v in ref_cols]
    print("## Overall (geomean of all 20 kernels)\n")
    print("| rank | system | all-20 geomean |")
    print("|---|---|---|")
    for i, (c, g) in enumerate(sorted(combined, key=lambda t: -t[1]), 1):
        print(f"| {i} | {c} | {fmt(g)} |")
    print("\n## Models\n")
    table([sys_cols[i] for i in order], rows([sys_vals[i] for i in order]))
    flagged = [sys_cols[i] for i in order if sys_vals[i]["oob"]]
    if flagged:
        print(f"Includes runs with an out-of-range access on some kernels (correct results, a failure "
              f"under the harness rule): {', '.join(flagged)}. See analysis.md.\n")
    print("## Open-source reference cores\n")
    table([c for c, _ in ref_cols], rows([v for _, v in ref_cols]))


if __name__ == "__main__":
    main()
