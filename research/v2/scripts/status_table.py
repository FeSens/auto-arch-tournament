"""Campaign status table: every run (finished or live) with its champion score
after each round, final score, held-out score and outcome counts.

  python3 research/v2/scripts/status_table.py --results bench/v2/results.jsonl --rundir bench/v2
Prints Markdown."""
import argparse, json, re
from pathlib import Path

CLONES = Path("/srv/hwebench/clones")
RESCORED = Path("research/runs/EXP-2026-09-28-v2-main/incident_08/holdout_rescored.jsonl")
PILOTS = {"gpt-6-sol_xhigh-v2"}   # amendment 11: replaced by GPT-6.1 Sol, rep1 kept as a pilot
# Row order: by model (primary comparison first, pilot next to its successor), then by rep.
MODEL_ORDER = ["claude-opus-5_5_xhigh-v2", "gpt-6_1-sol_xhigh-v2", "gpt-6-sol_xhigh-v2", "gpt-6-luna_xhigh-v2",
               # amendment 13 extension systems
               "claude-sonnet-5-5_xhigh-v2", "gpt-6-astra_xhigh-v2", "gpt-5_5_xhigh-v2",
               # amendment 14 ablation (GPT-6.1 Sol, scribe skipped)
               "gpt-6_1-sol_xhigh-v2-nolessons"]
# External references (research/v2/reference_vexriscv, research/v2/reference_cores): open-source
# cores in the harness's Gowin flow (median of place options 0-2). Their CoreMark is Fmax x a
# published CoreMark/MHz, not a bench measurement; no held-out score (not run on the bench programs).
REFERENCES = Path("research/v2/reference_cores/references.json")
SIM_RESULTS = Path("research/v2/reference_cores/results_sim")


def references():
    out = []
    for ref in json.loads(REFERENCES.read_text()) if REFERENCES.is_file() else []:
        res = Path(ref["result"])
        if not res.is_file():
            continue
        s = json.loads(res.read_text())["summary"]
        if s.get("placement_failed"):
            continue
        r = {**ref, "fmax_mhz": s["fmax_mhz"], "lut4": s["lut4"], "measured": False,
             "score": s["fmax_mhz"] * ref["coremark_per_mhz"], "holdout": None}
        # Stage 2 (research/v2/reference_cores/sim): the bench's own CoreMark and
        # held-out ELFs in simulation, scored like the harness.
        sim = SIM_RESULTS / f"{ref['key']}.json"
        if sim.is_file():
            m = json.loads(sim.read_text())
            if m["coremark"]["valid"] and m["fmax_mhz"] == s["fmax_mhz"]:
                r.update(measured=True, score=m["coremark"]["score"],
                         holdout=m["holdout_geomean_iter_s"] or None)
        out.append(r)
    return sorted(out, key=lambda r: -r["score"])


def entries(path: Path):
    if not path.is_file():
        return []
    out = []
    for l in path.read_text(errors="replace").splitlines():
        try:
            out.append(json.loads(l))
        except ValueError:
            pass
    return out


def per_round(log):
    """Champion fitness after each round (accepted improvements only)."""
    best, rounds = None, {}
    for e in log:
        m = re.search(r"-r(\d+)s\d+$", e.get("id", ""))
        if e.get("id", "").startswith("baseline"):
            best = e.get("fitness")
            continue
        if not m:
            continue
        r = int(m.group(1))
        if e.get("outcome") == "improvement" and isinstance(e.get("fitness"), (int, float)):
            best = e["fitness"]
        rounds[r] = best
    return rounds


def champion(log):
    """The current champion's log entry: the last accepted one (the baseline counts)."""
    imp = [e for e in log if e.get("outcome") == "improvement" and isinstance(e.get("fitness"), (int, float))]
    return imp[-1] if imp else {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", type=Path, nargs="+", required=True,
                    help="results files; a later file's row for a run wins (amendment 11)")
    ap.add_argument("--rundir", type=Path, required=True)
    ap.add_argument("--rescored", type=Path, nargs="*", default=[RESCORED],
                    help="held-out scores recomputed after a run (incident 08), merged by model, rep, start")
    a = ap.parse_args()
    done = {(r["model"], r["rep"]): r for f in a.results for r in entries(f)}
    for f in a.rescored:
        for fix in entries(f):
            r = done.get((fix["model"], fix["rep"]))
            if r and r.get("started_at") == fix.get("attempt_started_at") and not r.get("holdout_geomean_iter_s"):
                r.update({k: fix.get(k) for k in ("holdout_geomean_iter_s", "holdout_fmax_mhz")})
    # A stopped pilot attempt is noise; its finished run stays listed.
    done = {k: r for k, r in done.items() if k[0] not in PILOTS or r.get("status") == "done"}
    runs = {}
    for k, r in done.items():
        runs[k] = (r, entries(a.rundir / r["model"] / f"rep{r['rep']}" / "log.jsonl"))
    for c in sorted(CLONES.glob("*-rep*")) if CLONES.is_dir() else []:
        m = re.match(r"(.+)-rep(\d+)$", c.name)
        k = (m.group(1), int(m.group(2)))
        # A live rerun replaces an earlier attempt that did not finish.
        if k not in runs or (runs[k][0] or {}).get("status") != "done":
            runs[k] = (None, entries(c / "cores/bench/experiments/log.jsonl"))
    nr = max([max(per_round(l) or {0: 0}) for _, l in runs.values()] or [0])
    head = ["run", "status"] + [f"r{i}" for i in range(1, nr + 1)] + \
           ["final", "Fmax MHz", "LUT4", "held-out iter/s", "acc/rej/broken"]
    print("| " + " | ".join(head) + " |")
    print("|" + "---|" * len(head))
    for (model, rep), (r, log) in sorted(runs.items(), key=lambda kv: (
            MODEL_ORDER.index(kv[0][0]) if kv[0][0] in MODEL_ORDER else len(MODEL_ORDER), kv[0][0], kv[0][1])):
        pr = per_round(log)
        cnt = {o: sum(1 for e in log if e.get("outcome") == o) for o in ("improvement", "regression", "broken")}
        acc = cnt["improvement"] - (1 if log and log[0].get("id", "").startswith("baseline") else 0)
        status = (r or {}).get("status", "running")
        cells = [f"{model} rep{rep}" + (" (pilot)" if model in PILOTS else ""), status] + [f"{pr[i]:.1f}" if pr.get(i) is not None else "" for i in range(1, nr + 1)]
        final = (r or {}).get("final_fitness")
        champ = champion(log)
        # Done: the held-out re-run Fmax. Running: the current champion's loop Fmax (dagger).
        fmax = (r or {}).get("holdout_fmax_mhz") if r else (f"{champ['fmax_mhz']}\u2020" if champ.get("fmax_mhz") else "")
        lut = f"{champ['lut4']:,}" + ("" if r else "\u2020") if champ.get("lut4") else ""
        cells += [f"{final:.2f}" if final else "",
                  f"{fmax or ''}", lut,
                  f"{(r or {}).get('holdout_geomean_iter_s'):.0f}" if (r or {}).get("holdout_geomean_iter_s") else "",
                  f"{acc}/{cnt['regression']}/{cnt['broken']}"]
        print("| " + " | ".join(cells) + " |")
    refs = references()
    for v in refs:
        print("| " + " | ".join([f"{v['name']} (reference)", "external"] + [""] * nr + [
            f"{v['score']:.1f}" + ("" if v["measured"] else "*"), f"{v['fmax_mhz']}", f"{v['lut4']:,}",
            f"{v['holdout']:.0f}" if v["holdout"] else "n/a", ""]) + " |")
    if refs:
        print("\nReferences: open-source cores in the same Gowin flow (Fmax, LUT4). CoreMark and held-out "
              "are measured in simulation on the bench's own ELFs with the harness's stall model and "
              "scoring, each core on its native bus with one-cycle synchronous memory "
              "(research/v2/reference_cores/README.md). *Not yet simulated: Fmax x published CoreMark/MHz "
              "(indicative only).")
    print("\u2020 Running rep: the current champion's loop measurement (Fmax, LUT4). Done reps show the "
          "held-out re-run Fmax and the final champion's LUT4.")


if __name__ == "__main__":
    main()
