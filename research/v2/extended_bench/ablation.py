"""Amendment 14 on the extended suite (exploratory): GPT-6.1 Sol full
(results/champions.json) vs no lessons (results/ablation_champions.json,
run_champions.py --ablation) on the 15 kernels no agent saw, with the same
Welch-on-ln and bootstrap as the pre-registered held-out test.

    python3 -B ablation.py > results/ablation.md
"""
import json
import math
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[0] / "scripts"))
import analyze_main as am  # noqa: E402

HELD_OUT = ("dhrystone", "aha-mont64", "crc32", "matmult-int", "edn")
FULL, NOLESSONS = "gpt-6_1-sol_xhigh-v2", "gpt-6_1-sol_xhigh-v2-nolessons"


def gm(xs):
    return math.exp(statistics.fmean(math.log(x) for x in xs))


def per_run(champs, model):
    out = []
    for c in sorted((c for c in champs if c["model"] == model), key=lambda c: c["rep"]):
        ks = c["kernels"]
        assert all(v["correct"] and v["valid"] for v in ks.values()), (model, c["rep"])
        new = [k for k in ks if k not in HELD_OUT]
        out.append({"rep": c["rep"], "held_out": c["holdout_geomean_iter_s"],
                    "new15": gm([ks[k]["iter_s"] for k in new])})
    return out


def main():
    champs = json.loads((HERE / "results/champions.json").read_text())
    abl = json.loads((HERE / "results/ablation_champions.json").read_text())
    full, nl = per_run(champs, FULL), per_run(abl, NOLESSONS)
    assert len(full) == len(nl) == 6
    print("# Amendment 14 ablation on the extended suite (exploratory)\n")
    print("| arm | rep | held-out | new-15 |\n|---|---|---|---|")
    for name, rs in (("full", full), ("no lessons", nl)):
        for r in rs:
            print(f"| {name} | {r['rep']} | {r['held_out']:.0f} | {r['new15']:.0f} |")
    print(f"\nGeomeans: full held-out {gm([r['held_out'] for r in full]):.0f}, new-15 "
          f"{gm([r['new15'] for r in full]):.0f}; no lessons held-out {gm([r['held_out'] for r in nl]):.0f}, "
          f"new-15 {gm([r['new15'] for r in nl]):.0f}.\n")
    out = {}
    for key in ("held_out", "new15"):
        a = [math.log(r[key]) for r in full]
        b = [math.log(r[key]) for r in nl]
        res = am.welch(a, b)
        res["boot95"] = am.bootstrap_ratio(a, b)
        out[key] = res
        print(f"{key}: full / no lessons {res['ratio']:.3f}, 95% CI [{res['ci95'][0]:.3f}, "
              f"{res['ci95'][1]:.3f}], bootstrap [{res['boot95'][0]:.3f}, {res['boot95'][1]:.3f}], "
              f"p = {res['p']:.3f}")
    (HERE / "results/ablation.json").write_text(json.dumps({"full": full, "nolessons": nl, **out}, indent=1))


if __name__ == "__main__":
    main()
