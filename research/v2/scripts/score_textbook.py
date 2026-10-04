#!/usr/bin/env python3
"""Score V0 and the textbook-edit baseline with the harness's own evals
(amendment 15, part B).

For each design, a scratch tree is made from the bench-v2.8.3 fixture
(`git archive hwe-bench-v2.8.3`) with a private copy of riscv-formal (the
main checkout's copy is never written). The textbook design gets
research/v2/textbook_baseline/rtl and its unit tests copied over V0's. Then,
in the order and with the functions a tournament slot uses
(tools/tournament.py): emit_verilog (lint, bench ELFs, cosim build), the RVFI
ch0 precheck, run_formal, run_cosim, run_fpga_eval (CoreMark fitness, Gowin
Fmax), and, as the runner scores a finished rep (tools/bench/transfer.py),
measure_fmax plus run_holdout with the main checkout's held-out ELFs. The
cocotb unit tests run last. Every stage runs even if an earlier gate fails,
so the record is complete; `gates_passed` says whether the design would have
been accepted as a candidate.

    python3 -B research/v2/scripts/score_textbook.py [v0] [textbook]

Writes research/v2/textbook_baseline/results/<design>.json.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO))

TAG = "hwe-bench-v2.8.3"
TARGET = "bench"
BASE = REPO / "research/v2/textbook_baseline"
WORK = Path("/home/bench/textbook-score")


def make_tree(design: str) -> Path:
    tree = WORK / design
    if tree.exists():
        shutil.rmtree(tree)
    tree.mkdir(parents=True)
    archive = subprocess.run(["git", "-C", str(REPO), "archive", TAG], check=True,
                             capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", str(tree)], input=archive, check=True)
    shutil.copytree(REPO / "formal/riscv-formal", tree / "formal/riscv-formal", symlinks=True)
    if design == "textbook":
        rtl = tree / "cores" / TARGET / "rtl"
        for f in sorted((BASE / "rtl").glob("*.sv")):
            shutil.copy(f, rtl / f.name)
        for f in sorted((BASE / "test").glob("test_*.py")):
            shutil.copy(f, tree / "cores" / TARGET / "test" / f.name)
    subprocess.run(["git", "init", "-q"], cwd=tree, check=True)
    subprocess.run(["git", "add", "-A"], cwd=tree, check=True)
    subprocess.run(["git", "-c", "user.name=score", "-c", "user.email=score@localhost",
                    "commit", "-qm", f"{design} on {TAG}"], cwd=tree, check=True)
    return tree


def timed(rec: dict, name: str, fn):
    t = time.time()
    try:
        out = fn()
    except Exception as e:  # recorded, the next stage still runs
        out = {"exception": f"{type(e).__name__}: {e}"[:2000]}
    rec["seconds"][name] = round(time.time() - t, 1)
    return out


def score(design: str) -> dict:
    from tools.orchestrator import emit_verilog
    from tools.eval.rvfi_lint import check_ch0_contract
    from tools.eval.formal import run_formal
    from tools.eval.cosim import run_cosim
    from tools.eval.fpga import run_fpga_eval, measure_fmax
    from tools.eval.holdout import run_holdout

    tree = make_tree(design)
    wt = str(tree)
    rec: dict = {"design": design, "fixture": TAG, "tree": wt, "seconds": {},
                 "started": datetime.now(timezone.utc).isoformat()}
    build = timed(rec, "build", lambda: emit_verilog(wt, target=TARGET))
    rec["build"] = build if isinstance(build, dict) else {"ok": build[0], "reason": build[1][-2000:]}
    rec["ch0_contract"] = check_ch0_contract(tree / "cores" / TARGET / "rtl")
    rec["formal"] = timed(rec, "formal", lambda: run_formal(wt, target=TARGET))
    rec["cosim"] = timed(rec, "cosim", lambda: run_cosim(wt, target=TARGET))
    fpga = timed(rec, "fpga", lambda: run_fpga_eval(wt, target=TARGET))
    rec["fpga"] = {k: v for k, v in fpga.items() if k != "critical_paths"} | (
        {"critical_paths": fpga["critical_paths"][:2]} if fpga.get("critical_paths") else {})
    final = timed(rec, "final_fmax", lambda: measure_fmax(wt, TARGET))
    rec["final_fmax"] = final
    if final.get("fmax_mhz"):
        rec["holdout"] = timed(rec, "holdout", lambda: run_holdout(
            wt, TARGET, final["fmax_mhz"], holdout_dir=str(REPO)))
    tests = timed(rec, "unit_tests", lambda: subprocess.run(
        [sys.executable, "-m", "pytest", "-q", "test/"], cwd=tree / "cores" / TARGET,
        capture_output=True, text=True, timeout=3600))
    rec["unit_tests"] = ({"returncode": tests.returncode, "tail": tests.stdout[-1500:]}
                         if hasattr(tests, "returncode") else tests)
    rec["gates_passed"] = bool(
        rec["build"].get("ok") and rec["ch0_contract"].get("passed")
        and rec["formal"].get("passed") and rec["cosim"].get("passed")
        and fpga.get("fitness") and not fpga.get("placement_failed")
        and not fpga.get("bench_failed"))
    rec["ended"] = datetime.now(timezone.utc).isoformat()
    return rec


def main(argv: list[str]) -> int:
    designs = argv or ["v0", "textbook"]
    out = BASE / "results"
    out.mkdir(exist_ok=True)
    for d in designs:
        rec = score(d)
        (out / f"{d}.json").write_text(json.dumps(rec, indent=1, default=str) + "\n")
        h = rec.get("holdout") or {}
        print(f"{d}: gates_passed={rec['gates_passed']} formal={rec['formal'].get('passed')} "
              f"cosim={rec['cosim'].get('passed')} fitness={rec['fpga'].get('fitness')} "
              f"fmax={rec['final_fmax'].get('fmax_mhz')} heldout={h.get('geomean_iter_s')}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
