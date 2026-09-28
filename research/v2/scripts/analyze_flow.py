#!/usr/bin/env python3
"""Analysis for EXP-2026-09-27-v2-synth-flow (rules in its prereg.yaml).

Baseline flow ('') rows come from the placement-noise runs.jsonl (the
current synth.tcl is deterministic, so they are reused, seeds 1-2 only);
flows A/B/C from this experiment's runs.jsonl.

Usage: analyze_flow.py <placement-noise runs.jsonl> <synth-flow runs.jsonl>
"""
import json
import math
import statistics as st
import sys
from collections import defaultdict

DESIGNS = ["V0", "gpt-5_6-sol_rep1", "gpt-5_6-terra_rep3"]
FLOWS = {"baseline": "", "A": "-family gw2a", "B": "-family gw2a -noabc9",
         "C": "-family gw2a -retime"}
SEEDS = (1, 2)


def load(paths):
    # flow -> design -> k -> seed -> (fmax, lut4)
    d = defaultdict(lambda: defaultdict(lambda: defaultdict(dict)))
    for p in paths:
        for line in open(p):
            r = json.loads(line)
            if "error" in r or r["design"] not in DESIGNS or r["seed"] not in SEEDS:
                continue
            d[r.get("flow", "")][r["design"]][r["k"]][r["seed"]] = (r["fmax_mhz"], r.get("lut4"))
    return d


def main():
    d = load(sys.argv[1:3])
    summary = {}
    print("| flow | design | variants | median Fmax | median LUT4 | SD ln(variant Fmax) | failed placements |")
    print("|---|---|---|---|---|---|---|")
    for name, flow in FLOWS.items():
        sds, per = [], {}
        for des in DESIGNS:
            ks = d[flow][des]
            vals, luts, failed = [], [], 0
            for k, seeds in ks.items():
                f = [seeds[s][0] for s in SEEDS if s in seeds and seeds[s][0]]
                failed += sum(1 for s in SEEDS if s in seeds and not seeds[s][0])
                luts += [seeds[s][1] for s in SEEDS if s in seeds and seeds[s][1]]
                if f:
                    vals.append(st.mean(f))
            if len(vals) < 3:
                print(f"| {name} | {des} | {len(vals)} | incomplete | | | |")
                continue
            sd = st.stdev([math.log(v) for v in vals])
            sds.append(sd)
            per[des] = (st.median(vals), st.median(luts))
            print(f"| {name} | {des} | {len(vals)} | {st.median(vals):.2f} | {st.median(luts):.0f} | {sd:.4f} | {failed} |")
        if len(sds) == len(DESIGNS):
            summary[name] = (math.sqrt(sum(s * s for s in sds) / len(sds)), per)
    print("\n| flow | sigma_flow (RMS over designs) |\n|---|---|")
    for n, (s, _) in summary.items():
        print(f"| {n} | {s:.4f} |")

    # Decision rule (prereg): among A, B, C the lowest sigma whose median Fmax
    # >= 0.9x A's and median LUT4 <= 1.1x A's for every design; differences
    # below 25% relative to A are not distinguishable -> A.
    if "A" not in summary:
        print("\ndecision: blocked (flow A incomplete)")
        return
    sA, pA = summary["A"]
    ok = []
    for n in ("A", "B", "C"):
        if n not in summary:
            continue
        s, p = summary[n]
        if all(p[x][0] >= 0.9 * pA[x][0] and p[x][1] <= 1.1 * pA[x][1] for x in DESIGNS):
            ok.append((s, n))
    s, best = min(ok)
    if best != "A" and s > 0.75 * sA:
        print(f"\ndecision: A (best {best} sigma {s:.4f} is within 25% of A's {sA:.4f})")
    else:
        print(f"\ndecision: {best} (sigma {s:.4f}; A {sA:.4f})")


if __name__ == "__main__":
    main()
