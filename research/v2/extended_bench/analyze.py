"""Exploratory analysis of the extended suite (not pre-registered).

Scores every finished champion and every reference core on 20 benchmarks:
the five held-out kernels (the pre-registered held-out score) and 15 more
Embench-IoT kernels. Reports, per system, the geomean over the 15 new
kernels and over all 20, the pairwise ratios with Welch CIs and the
descriptive rank order (functions from research/v2/scripts/analyze_main.py),
the run-level rank agreement between the held-out score and the new-kernel
score, and per-kernel system geomeans with the reference cores beside them.

    python3 -B analyze.py [--json out.json] > results/analysis.md
"""
import itertools
import json
import math
import statistics
import sys
from pathlib import Path

REPO = Path("/home/bench/auto-arch-tournament")
sys.path.insert(0, str(REPO / "research/v2/scripts"))
import analyze_main as am  # noqa: E402

HERE = Path(__file__).resolve().parent
NAMES = {"claude-opus-5_5_xhigh-v2": "Opus 5.5", "claude-sonnet-5-5_xhigh-v2": "Sonnet 5.5",
         "gpt-6_1-sol_xhigh-v2": "GPT-6.1 Sol", "gpt-6-astra_xhigh-v2": "GPT-6 Astra",
         "gpt-6-luna_xhigh-v2": "Luna", "gpt-5_5_xhigh-v2": "GPT-5.5"}
PILOT = "gpt-6-sol_xhigh-v2"
HELD_OUT = ("dhrystone", "aha-mont64", "crc32", "matmult-int", "edn")


def gm(xs):
    return math.exp(statistics.fmean(map(math.log, xs)))


def kendall_tau(x, y):
    c = d = 0
    for i, j in itertools.combinations(range(len(x)), 2):
        s = (x[i] - x[j]) * (y[i] - y[j])
        c += s > 0
        d += s < 0
    return (c - d) / (c + d) if c + d else float("nan")


def main(argv):
    champs = json.loads((HERE / "results/champions.json").read_text())
    refs = json.loads((HERE / "results/references.json").read_text())
    kernels = sorted(champs[0]["kernels"])
    new = [k for k in kernels if k not in HELD_OUT]
    out = {"kernels": kernels, "new_kernels": new, "systems": {}, "pairs": [], "references": {}}

    wrong = [(c["model"], c["rep"], k, v.get("reason")) for c in champs for k, v in c["kernels"].items()
             if not v["correct"]]
    oob = {}
    for c in champs:
        ks = sorted(k for k, v in c["kernels"].items() if v.get("oob"))
        if ks:
            oob[f"{NAMES.get(c['model'], c['model'])} rep{c['rep']}"] = ks
    mism = [(c["model"], c["rep"], k) for c in champs for k, v in c["check"].items() if not v["match"]]
    total = sum(len(c["kernels"]) for c in champs)
    print("# Extended benchmark suite (exploratory, not pre-registered)\n")
    print(f"{len(champs)} finished champion runs x {len(kernels)} benchmarks "
          f"({len(HELD_OUT)} held-out + {len(new)} new Embench-IoT kernels); "
          f"{len(refs)} reference cores.\n")
    print(f"Correct results: {total - len(wrong)} of {total} champion runs (wrong or incomplete: "
          f"{wrong or 'none'}). Out-of-range access (CLAUDE.md invariant 6, a failure under the "
          f"harness's rule): {oob or 'none'}. Held-out cycle counts reproduced exactly for "
          f"{sum(len(c['check']) for c in champs) - len(mism)} of {sum(len(c['check']) for c in champs)} "
          f"(mismatches: {mism or 'none'}).\n")
    out["oob"] = oob
    out["wrong"] = wrong

    # Per run. new15 / all20: geomean of the correct results (performance view).
    # new15_harness: the harness's held-out rule, geomean over the kernels that
    # pass its checks (an out-of-range access fails), with all_valid beside it.
    per_run = []
    for c in champs:
        ks = c["kernels"]
        ok = all(ks[k]["correct"] for k in kernels)
        valid = [ks[k]["iter_s"] for k in new if ks[k]["valid"]]
        per_run.append({"model": c["model"], "rep": c["rep"], "held_out": c["holdout_geomean_iter_s"],
                        "new15": gm([ks[k]["iter_s"] for k in new]) if ok else 0.0,
                        "all20": gm([ks[k]["iter_s"] for k in kernels]) if ok else 0.0,
                        "new15_harness": gm(valid) if valid else 0.0,
                        "all_valid": len(valid) == len(new)})
    out["runs"] = per_run
    flagged = [r for r in per_run if not r["all_valid"]]
    for r in flagged:
        print(f"{NAMES.get(r['model'], r['model'])} rep{r['rep']}: new-15 geomean {r['new15']:.1f} from correct "
              f"results; {r['new15_harness']:.1f} under the harness rule (geomean over the kernels it "
              f"passes, all_validated false).\n")

    systems = [m for m in NAMES if any(r["model"] == m for r in per_run)]
    print("## Per system (scored runs; pilot excluded)\n")
    print("| system | n | held-out geomean | new-15 geomean | all-20 geomean | SD ln (new-15) |")
    print("|---|---|---|---|---|---|")
    ln_new, ln_ho = {}, {}
    for m in systems:
        rs = [r for r in per_run if r["model"] == m]
        if any(r["new15"] == 0 for r in rs):
            ln_new[m] = None
        else:
            ln_new[m] = [math.log(r["new15"]) for r in rs]
        ln_ho[m] = [math.log(r["held_out"]) for r in rs]
        s = {"n": len(rs), "held_out": gm([r["held_out"] for r in rs]),
             "new15": gm([r["new15"] for r in rs]) if ln_new[m] else 0.0,
             "all20": gm([r["all20"] for r in rs]) if ln_new[m] else 0.0,
             "sd_ln_new15": statistics.stdev(ln_new[m]) if ln_new[m] and len(rs) > 1 else None}
        out["systems"][NAMES[m]] = s
        print(f"| {NAMES[m]} | {s['n']} | {s['held_out']:.1f} | {s['new15']:.1f} | {s['all20']:.1f} | "
              f"{s['sd_ln_new15']:.3f} |" if s["sd_ln_new15"] is not None else
              f"| {NAMES[m]} | {s['n']} | {s['held_out']:.1f} | {s['new15']:.1f} | {s['all20']:.1f} | |")

    order_ho = sorted(systems, key=lambda m: -out["systems"][NAMES[m]]["held_out"])
    order_new = sorted(systems, key=lambda m: -out["systems"][NAMES[m]]["new15"])
    print("\nSystem order, held-out: " + " > ".join(NAMES[m] for m in order_ho))
    print("System order, new-15:   " + " > ".join(NAMES[m] for m in order_new))

    full = [m for m in systems if ln_new[m] and len(ln_new[m]) >= 6]
    if len(full) >= 2:
        ri = am.rank_intervals({NAMES[m]: ln_new[m] for m in full})
        print("\n## Rank intervals on the new-15 score (systems with 6 runs; 95% bootstrap)\n")
        print("| system | geomean new-15 | rank interval |")
        print("|---|---|---|")
        for m in sorted(full, key=lambda m: -out["systems"][NAMES[m]]["new15"]):
            print(f"| {NAMES[m]} | {out['systems'][NAMES[m]]['new15']:.1f} | {ri[NAMES[m]][0]} to {ri[NAMES[m]][1]} |")
        print("\n## Pairwise on the new-15 score (Welch on ln; Holm across the pairs shown)\n")
        pairs = list(itertools.combinations(sorted(full, key=lambda m: -out["systems"][NAMES[m]]["new15"]), 2))
        res = [am.welch(ln_new[a], ln_new[b]) for a, b in pairs]
        for (a, b), r, ph in zip(pairs, res, am.holm([r["p"] for r in res])):
            print(f"{NAMES[a]} vs {NAMES[b]}: ratio {r['ratio']:.3f}, 95% CI [{r['ci95'][0]:.3f}, {r['ci95'][1]:.3f}], "
                  f"p = {r['p']:.4f}, Holm p = {ph:.4f}")
            out["pairs"].append({"a": NAMES[a], "b": NAMES[b], **r, "p_holm": ph})

    scored = [r for r in per_run if r["model"] != PILOT and r["new15"] > 0]
    tau = kendall_tau([r["held_out"] for r in scored], [r["new15"] for r in scored])
    out["kendall_tau_runs"] = tau
    print(f"\n## Agreement\n\nRun level ({len(scored)} scored runs): Kendall tau between the held-out "
          f"score and the new-15 score = {tau:.3f}.")
    agree = 0
    for k in new:
        g = {m: gm([c["kernels"][k]["iter_s"] for c in champs if c["model"] == m]) for m in systems
             if all(c["kernels"][k]["correct"] for c in champs if c["model"] == m)}
        agree += sorted(g, key=lambda m: -g[m])[:1] == order_ho[:1]
    print(f"Kernel level: the held-out leader ({NAMES[order_ho[0]]}) has the highest system geomean "
          f"on {agree} of {len(new)} new kernels.")

    print("\n## Per kernel, system geomean iter/s (references at their stage 1 Fmax)\n")
    cols = [NAMES[m] for m in order_ho] + [r["name"] for r in refs]
    print("| kernel | " + " | ".join(cols) + " |")
    print("|---|" + "---|" * len(cols))
    for k in HELD_OUT + tuple(new):
        cells = []
        for m in order_ho:
            v = [c["kernels"][k] for c in champs if c["model"] == m]
            cells.append((f"{gm([x['iter_s'] for x in v]):.0f}" + ("\u2021" if any(x.get("oob") for x in v) else ""))
                         if all(x["correct"] for x in v) else "fail")
        for r in refs:
            x = r["kernels"][k]
            cells.append((f"{x['iter_s']:.0f}" + ("\u2021" if x.get("oob") else "")) if x["correct"] else "fail")
        print(f"| {k}{' (held-out)' if k in HELD_OUT else ''} | " + " | ".join(cells) + " |")
    print("\n\u2021 includes a run with an out-of-range access (a failure under the harness rule; the "
          "result was correct).")
    rows = []
    for r in refs:
        ok = all(r["kernels"][k]["correct"] for k in kernels)
        g15 = gm([r["kernels"][k]["iter_s"] for k in new]) if ok else 0.0
        g5 = gm([r["kernels"][k]["iter_s"] for k in HELD_OUT]) if ok else 0.0
        out["references"][r["name"]] = {"fmax_mhz": r["fmax_mhz"], "held_out": g5, "new15": g15,
                                        "failed": [k for k in kernels if not r["kernels"][k]["valid"]]}
        rows.append((g15, r["name"], g5, r["fmax_mhz"]))
    print("\n## Reference cores, geomean iter/s\n")
    print("| reference | Fmax MHz | held-out-5 | new-15 |")
    print("|---|---|---|---|")
    for g15, name, g5, f in sorted(rows, reverse=True):
        print(f"| {name} | {f} | {g5:.0f} | {g15:.0f} |")
    if "--json" in argv:
        Path(argv[argv.index("--json") + 1]).write_text(json.dumps(out, indent=1))


if __name__ == "__main__":
    main(sys.argv[1:])
