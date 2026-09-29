"""Held-out score of a 2.8.0 rep1 champion whose repo.bundle the runner failed
to write (relative --results-dir; V2 2.8.0 campaign).

    recon_score.py <rep_dir> <out_json> (--bundle <rescued.bundle> | --final-rtl)

--final-rtl: rebuild the champion tree as the fixture's root tree (identical
across runs: tree 6ca282be) with the rep's saved final-rtl/ as
cores/bench/rtl, committed on top; used for Opus rep1, whose clone was
deleted. --bundle: a bundle the rescue watcher took of the live clone.

Then (1) verify: emit_verilog + run_fpga_eval on the tree must reproduce the
champion's log row (cycles, LUT4, Fmax per placement option); (2) score:
tools.bench.runner.score_holdout on a scratch rep dir holding the bundle,
summary.json and log.jsonl, i.e. the exact code path the runner takes.
"""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path("/home/bench/auto-arch-tournament")
sys.path.insert(0, str(REPO))
FIXTURE_BUNDLE = Path("/home/bench/rescue-bundles/gpt-6-sol_xhigh-v2-rep1.bundle")
ROOT_TREE = "6ca282beb2eb65a323f14f49daf0b671bb544f23"


def git(*a, cwd):
    return subprocess.run(["git", *a], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def rebuild_from_final_rtl(rep_dir: Path, work: Path) -> Path:
    tree = work / "tree"
    git("clone", "-q", str(FIXTURE_BUNDLE), str(tree), cwd=work)
    root = git("rev-list", "--max-parents=0", "HEAD", cwd=tree)
    assert git("rev-parse", f"{root}^{{tree}}", cwd=tree) == ROOT_TREE
    git("checkout", "-q", "-B", "bench-v2.8", root, cwd=tree)
    rtl = tree / "cores/bench/rtl"
    git("rm", "-q", "-r", "cores/bench/rtl", cwd=tree)
    shutil.copytree(rep_dir / "final-rtl", rtl)
    git("add", "cores/bench/rtl", cwd=tree)
    git("-c", "user.name=HWE Bench", "-c", "user.email=hwe-bench@localhost",
        "commit", "-q", "-m", f"reconstructed champion: fixture root + {rep_dir}/final-rtl", cwd=tree)
    bundle = work / "repo.bundle"
    git("bundle", "create", str(bundle), "--all", cwd=tree)
    return bundle


def main():
    rep_dir, out_json, mode = Path(sys.argv[1]).resolve(), Path(sys.argv[2]), sys.argv[3]
    work = Path(tempfile.mkdtemp(prefix="recon-", dir="/tmp/claude-1000"))
    if mode == "--final-rtl":
        bundle = rebuild_from_final_rtl(rep_dir, work)
    else:
        bundle = Path(sys.argv[4]).resolve()
    # Scratch rep dir named <model>/rep<N> (score_rep parses the last two parts).
    scratch_rep = work / rep_dir.parent.name / rep_dir.name
    scratch_rep.mkdir(parents=True)
    for f in ("summary.json", "log.jsonl"):
        shutil.copy2(rep_dir / f, scratch_rep / f)
    shutil.copy2(bundle, scratch_rep / "repo.bundle")

    # (1) Verify against the champion's log row with the loop's own eval.
    rows = [json.loads(l) for l in (rep_dir / "log.jsonl").read_text().splitlines() if l.strip()]
    champ = [r for r in rows if r.get("outcome") == "improvement"][-1]
    from tools.orchestrator import emit_verilog
    from tools.eval.fpga import run_fpga_eval
    tree = work / "verify"
    git("clone", "-q", str(scratch_rep / "repo.bundle"), str(tree), cwd=work)
    ok, why = emit_verilog(str(tree), target="bench")
    assert ok, why
    ev = run_fpga_eval(str(tree), target="bench")
    verify = {k: {"log": champ.get(k), "rebuilt": ev.get(k)} for k in ("fitness", "cycles", "lut4", "fmax_mhz", "seeds")}

    # (2) The runner's own held-out scoring.
    from tools.bench.runner import score_holdout
    held = score_holdout(scratch_rep)
    out = {"rep_dir": str(rep_dir), "mode": mode, "champion_id": champ.get("id"),
           "verify": verify, "holdout": held}
    out_json.write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    if mode == "--final-rtl":
        shutil.copy2(bundle, rep_dir.parent / f"{rep_dir.name}.reconstructed.bundle")


if __name__ == "__main__":
    main()
