#!/usr/bin/env python3
"""Amendment 15 part C analysis: do the V2 designs and the system ranking hold
on an AMD Artix-7 200T? Exploratory; no V2 verdict changes.

Each design's Artix-7 held-out score is the geomean over the five kernels of
Fmax_A x 1e6 x reps / cycles, with the reps and cycles of its scored held-out
run (cycle counts come from RTL simulation and do not depend on the FPGA).
Fmax_A is the median of the three pass-2 Vivado builds
(research/v2/xfpga/results/<design>.json).

(1) Kendall tau-b between the six systems' geometric-mean held-out scores on
Gowin and on Artix-7; Spearman rho over the 36 runs and over all designs with
the ten reference cores. (2) The prereg primary test, the amendment 01 pair and
the amendment 13 extension family recomputed on Artix-7 scores with the
functions of research/v2/scripts/analyze_main.py, side by side with Gowin.
(3) Artix-7 / Gowin Fmax ratio, agents' finals vs reference cores, Welch on
ln(ratio).

    python3 -B research/v2/xfpga/analyze_xfpga.py

Writes research/v2/xfpga/results/analysis.{json,md}.
"""
from __future__ import annotations

import json
import math
import statistics
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "research/v2/scripts"))
import analyze_main as am  # noqa: E402

XF = REPO / "research/v2/xfpga/results"
EXP = REPO / "research/runs/EXP-2026-09-28-v2-main"
RESULTS = [REPO / "bench/v2" / f for f in (
    "results.jsonl", "results-opus-luna.jsonl", "results-sol61.jsonl",
    "results-astra.jsonl", "results-sonnet55.jsonl", "results-gpt55.jsonl")]
RESCORED = [EXP / "incident_08/holdout_rescored.jsonl"]
REFS = ["vexriscv_maxperf", "vexriscv_nocache", "vexiiriscv", "hazard3", "ibex_maxperf",
        "ibex_small", "ueriscv", "neorv32", "biriscv", "picorv32"]
SYSTEMS = list(am.SHORT)


def geomean(xs):
    return math.exp(statistics.fmean(math.log(x) for x in xs))


def heldout(fmax_mhz: float, kernels: dict) -> float:
    return geomean([fmax_mhz * 1e6 * k["reps"] / k["cycles"] for k in kernels.values()])


def ranks(xs):
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    r = [0.0] * len(xs)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and xs[order[j + 1]] == xs[order[i]]:
            j += 1
        for k in range(i, j + 1):
            r[order[k]] = (i + j) / 2 + 1
        i = j + 1
    return r


def spearman(x, y):
    rx, ry = ranks(x), ranks(y)
    mx, my = statistics.fmean(rx), statistics.fmean(ry)
    num = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    return num / math.sqrt(sum((a - mx) ** 2 for a in rx) * sum((b - my) ** 2 for b in ry))


def kendall_tau_b(x, y):
    n, conc, disc, tx, ty = len(x), 0, 0, 0, 0
    for i in range(n):
        for j in range(i + 1, n):
            dx, dy = x[i] - x[j], y[i] - y[j]
            if dx == 0 and dy == 0:
                continue
            if dx == 0:
                tx += 1
            elif dy == 0:
                ty += 1
            elif dx * dy > 0:
                conc += 1
            else:
                disc += 1
    return (conc - disc) / math.sqrt((conc + disc + tx) * (conc + disc + ty))


def tests(ln: dict[str, list[float]]) -> dict:
    """The prereg primary, amendment 01 and amendment 13 families, as analyze_main.main runs them."""
    out = {}
    a, b = am.PRIMARY
    r = am.welch(ln[a], ln[b])
    r["boot95"] = am.bootstrap_ratio(ln[a], ln[b])
    r["verdict"] = am.verdict(r, r["p"], a, b)
    out["primary"] = {f"{am.SHORT[a]} vs {am.SHORT[b]}": r}
    for fam, pairs in (("secondary", am.SECONDARY),
                       ("extension", [(x, y) for i, x in enumerate(SYSTEMS) for y in SYSTEMS[i + 1:]
                                      if x in am.ADDED or y in am.ADDED])):
        res = [am.welch(ln[x], ln[y]) for x, y in pairs]
        for r, p_adj, (x, y) in zip(res, am.holm([r["p"] for r in res]), pairs):
            r["p_holm"] = p_adj
            r["boot95"] = am.bootstrap_ratio(ln[x], ln[y])
            r["verdict"] = am.verdict(r, p_adj, x, y)
        out[fam] = {f"{am.SHORT[x]} vs {am.SHORT[y]}": r for r, (x, y) in zip(res, pairs)}
    ri = am.rank_intervals(ln)
    order = sorted(ln, key=lambda m: statistics.fmean(ln[m]), reverse=True)
    out["ranking"] = [{"system": am.SHORT[m], "geomean": math.exp(statistics.fmean(ln[m])),
                       "rank95": ri[m]} for m in order]
    return out


def main() -> int:
    scored, _ = am.load(RESULTS, RESCORED)
    runs = []
    for (m, rep), row in sorted(scored.items()):
        if m not in am.SHORT:
            continue
        x = json.loads((XF / f"{m}_rep{rep}.json").read_text())
        assert x["status"] == "ok" and x["complete"], (m, rep)
        k = row["holdout_kernels"]
        assert all(v.get("validated") for v in k.values()), (m, rep)
        g_check = heldout(row["holdout_fmax_mhz"], k)
        assert abs(g_check / row["holdout_geomean_iter_s"] - 1) < 1e-6, (m, rep, g_check)
        fa = x["fmax_mhz"]
        runs.append({"system": am.SHORT[m], "model": m, "rep": rep,
                     "gowin_fmax": row["holdout_fmax_mhz"], "artix_fmax": fa,
                     "gowin_heldout": row["holdout_geomean_iter_s"], "artix_heldout": heldout(fa, k),
                     "gowin_coremark": row["best_fitness"],
                     "artix_coremark": fa * 1e6 * row["best_iterations"] / row["best_cycles"],
                     "artix_luts": x["area"].get("slice_luts"), "artix_ffs": x["area"].get("slice_registers")})
    assert len(runs) == 36, len(runs)
    refs = []
    for r in REFS:
        sim = json.loads((REPO / f"research/v2/reference_cores/results_sim/{r}.json").read_text())
        x = json.loads((XF / f"{r}.json").read_text())
        assert x["status"] == "ok" and x["complete"], r
        k = sim["holdout"]
        assert all(v["valid"] for v in k.values()), r
        g = heldout(sim["fmax_mhz"], k)
        assert abs(g / sim["holdout_geomean_iter_s"] - 1) < 1e-6, (r, g)
        refs.append({"design": r, "gowin_fmax": sim["fmax_mhz"], "artix_fmax": x["fmax_mhz"],
                     "gowin_heldout": g, "artix_heldout": heldout(x["fmax_mhz"], k)})

    ln_g = {m: [math.log(r["gowin_heldout"]) for r in runs if r["model"] == m] for m in SYSTEMS}
    ln_a = {m: [math.log(r["artix_heldout"]) for r in runs if r["model"] == m] for m in SYSTEMS}
    gm_g = [math.exp(statistics.fmean(ln_g[m])) for m in SYSTEMS]
    gm_a = [math.exp(statistics.fmean(ln_a[m])) for m in SYSTEMS]
    gm_fg = [geomean([r["gowin_fmax"] for r in runs if r["model"] == m]) for m in SYSTEMS]
    gm_fa = [geomean([r["artix_fmax"] for r in runs if r["model"] == m]) for m in SYSTEMS]

    allg = [r["gowin_heldout"] for r in runs] + [r["gowin_heldout"] for r in refs]
    alla = [r["artix_heldout"] for r in runs] + [r["artix_heldout"] for r in refs]
    ratio_ag = [math.log(r["artix_fmax"] / r["gowin_fmax"]) for r in runs]
    ratio_ref = [math.log(r["artix_fmax"] / r["gowin_fmax"]) for r in refs]
    w = am.welch(ratio_ag, ratio_ref)
    out = {
        "runs": runs, "refs": refs,
        "systems": [{"system": am.SHORT[m], "gowin_heldout_gm": g, "artix_heldout_gm": a,
                     "gowin_fmax_gm": fg, "artix_fmax_gm": fa}
                    for m, g, a, fg, fa in zip(SYSTEMS, gm_g, gm_a, gm_fg, gm_fa)],
        "kendall_tau_b_systems_heldout": kendall_tau_b(gm_g, gm_a),
        "kendall_tau_b_systems_fmax": kendall_tau_b(gm_fg, gm_fa),
        "spearman_runs_heldout": spearman([r["gowin_heldout"] for r in runs], [r["artix_heldout"] for r in runs]),
        "spearman_runs_fmax": spearman([r["gowin_fmax"] for r in runs], [r["artix_fmax"] for r in runs]),
        "spearman_all_designs_heldout": spearman(allg, alla),
        "tests_gowin": tests(ln_g), "tests_artix": tests(ln_a),
        "fmax_ratio": {"agents_gm": math.exp(statistics.fmean(ratio_ag)),
                       "agents_range": [math.exp(min(ratio_ag)), math.exp(max(ratio_ag))],
                       "refs_gm": math.exp(statistics.fmean(ratio_ref)),
                       "refs_range": [math.exp(min(ratio_ref)), math.exp(max(ratio_ref))],
                       "welch_agents_vs_refs": w,
                       "per_system_gm": {am.SHORT[m]: math.exp(statistics.fmean(
                           [math.log(r["artix_fmax"] / r["gowin_fmax"]) for r in runs if r["model"] == m]))
                           for m in SYSTEMS}},
    }
    (XF / "analysis.json").write_text(json.dumps(out, indent=1) + "\n")

    L = ["# Artix-7 cross-FPGA analysis (amendment 15 part C, exploratory)", ""]
    L += ["## Systems", "",
          "| system | held-out Gowin | held-out Artix-7 | Fmax Gowin | Fmax Artix-7 | Fmax ratio |",
          "|---|---|---|---|---|---|"]
    for s in out["systems"]:
        L.append(f"| {s['system']} | {s['gowin_heldout_gm']:,.0f} | {s['artix_heldout_gm']:,.0f} | "
                 f"{s['gowin_fmax_gm']:.1f} | {s['artix_fmax_gm']:.1f} | "
                 f"{out['fmax_ratio']['per_system_gm'][s['system']]:.2f} |")
    L += ["", "Geometric means over each system's six runs; held-out in iterations/s, Fmax in MHz.", ""]
    L += ["## Rank agreement", "",
          f"- Kendall tau-b, six systems, held-out: {out['kendall_tau_b_systems_heldout']:.3f} "
          f"(Fmax alone: {out['kendall_tau_b_systems_fmax']:.3f})",
          f"- Spearman rho, 36 runs, held-out: {out['spearman_runs_heldout']:.3f} "
          f"(Fmax alone: {out['spearman_runs_fmax']:.3f})",
          f"- Spearman rho, 36 runs plus 10 reference cores, held-out: {out['spearman_all_designs_heldout']:.3f}", ""]
    L += ["## Pre-registered tests on each FPGA", "",
          "| pair | Gowin ratio [95% CI] | Gowin p (Holm) | Artix-7 ratio [95% CI] | Artix-7 p (Holm) | separates on |",
          "|---|---|---|---|---|---|"]
    for fam in ("primary", "secondary", "extension"):
        for name, rg in out["tests_gowin"][fam].items():
            ra = out["tests_artix"][fam][name]
            pg, pa = rg.get("p_holm", rg["p"]), ra.get("p_holm", ra["p"])
            sg = "ranks higher" in rg["verdict"]
            sa = "ranks higher" in ra["verdict"]
            both = {(True, True): "both", (True, False): "Gowin only",
                    (False, True): "Artix-7 only", (False, False): "neither"}[(sg, sa)]
            L.append(f"| {name} ({fam}) | {rg['ratio']:.3f} [{rg['ci95'][0]:.3f}, {rg['ci95'][1]:.3f}] | {pg:.4f} | "
                     f"{ra['ratio']:.3f} [{ra['ci95'][0]:.3f}, {ra['ci95'][1]:.3f}] | {pa:.4f} | {both} |")
    L += ["", "| rank | Gowin | rank interval | Artix-7 | rank interval |", "|---|---|---|---|---|"]
    for i, (g, a) in enumerate(zip(out["tests_gowin"]["ranking"], out["tests_artix"]["ranking"]), 1):
        L.append(f"| {i} | {g['system']} {g['geomean']:,.0f} | {g['rank95'][0]} to {g['rank95'][1]} | "
                 f"{a['system']} {a['geomean']:,.0f} | {a['rank95'][0]} to {a['rank95'][1]} |")
    fr = out["fmax_ratio"]
    L += ["", "## Fmax ratio, Artix-7 / Gowin", "",
          f"- Agents' finals: geomean {fr['agents_gm']:.2f} (range {fr['agents_range'][0]:.2f} to "
          f"{fr['agents_range'][1]:.2f}); reference cores {fr['refs_gm']:.2f} "
          f"({fr['refs_range'][0]:.2f} to {fr['refs_range'][1]:.2f}).",
          f"- Welch on ln(ratio), agents vs references: ratio of geomeans {w['ratio']:.3f}, "
          f"95% CI [{w['ci95'][0]:.3f}, {w['ci95'][1]:.3f}], p = {w['p']:.2g}.", ""]
    L += ["## Reference cores", "", "| core | held-out Gowin | held-out Artix-7 | Fmax Gowin | Fmax Artix-7 |",
          "|---|---|---|---|---|"]
    for r in sorted(refs, key=lambda r: -r["artix_heldout"]):
        L.append(f"| {r['design']} | {r['gowin_heldout']:,.0f} | {r['artix_heldout']:,.0f} | "
                 f"{r['gowin_fmax']:.1f} | {r['artix_fmax']:.1f} |")
    (XF / "analysis.md").write_text("\n".join(L) + "\n")
    print("\n".join(L))
    return 0


if __name__ == "__main__":
    sys.exit(main())
