"""Campaign status table: every run (finished or live) with its champion score
after each round, final score, held-out score and outcome counts.

  python3 research/v2/scripts/status_table.py --results bench/v2/results.jsonl --rundir bench/v2
Prints Markdown."""
import argparse, json, re
from pathlib import Path

CLONES = Path("/srv/hwebench/clones")
RESCORED = Path("research/runs/EXP-2026-09-28-v2-main/incident_08/holdout_rescored.jsonl")
PILOTS = {"gpt-6-sol_xhigh-v2"}   # amendment 11: replaced by GPT-6.1 Sol, rep1 kept as a pilot


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
           ["final", "Fmax MHz", "held-out iter/s", "acc/rej/broken"]
    print("| " + " | ".join(head) + " |")
    print("|" + "---|" * len(head))
    for (model, rep), (r, log) in sorted(runs.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        pr = per_round(log)
        cnt = {o: sum(1 for e in log if e.get("outcome") == o) for o in ("improvement", "regression", "broken")}
        acc = cnt["improvement"] - (1 if log and log[0].get("id", "").startswith("baseline") else 0)
        status = (r or {}).get("status", "running")
        cells = [f"{model} rep{rep}" + (" (pilot)" if model in PILOTS else ""), status] + [f"{pr[i]:.1f}" if pr.get(i) is not None else "" for i in range(1, nr + 1)]
        final = (r or {}).get("final_fitness")
        cells += [f"{final:.2f}" if final else "", 
                  f"{(r or {}).get('holdout_fmax_mhz') or ''}",
                  f"{(r or {}).get('holdout_geomean_iter_s'):.0f}" if (r or {}).get("holdout_geomean_iter_s") else "",
                  f"{acc}/{cnt['regression']}/{cnt['broken']}"]
        print("| " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main()
