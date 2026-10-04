#!/usr/bin/env python3
"""Amendment 12, step 2: the harness's formal checks on a champion with its
formal-only (class b) branch replaced by the simulation/synthesis one.

Each case gets its own tree under ~/a12step2/<case>: the fixture
(`git archive bench-v2.8.2`, which reads the repository and writes nothing
into it), a copy of the riscv-formal checkout the clones copy
(formal/riscv-formal), and the run's final-rtl/ as cores/bench/rtl. The
patch keeps only the `else arm of the one class (b) branch; every other line,
including the class (a) branches, is the champion's. Formal is the fixture's
formal/run_all.sh with the nret=1 wrapper and checks config, the same
invocation tools/eval/formal.py makes (same depth), with a 6 h ceiling in
place of the harness's 2700 s.

    python3 -B research/v2/scripts/amendment12_step2.py <case> [--control] [--jobs N]

cases: opus-rep2 (if_stage.sv FS_IDX_W: 9 instead of 1 under RISCV_FORMAL),
sonnet55-rep5 (reg_file.sv: the RAM16SDP4 slice arm instead of the flop arm).
--control runs the unpatched champion (it passed in the campaign), to check
the tree reproduces the harness's verdict. Writes <tree>/step2_result.json.
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

REPO = Path("/home/bench/auto-arch-tournament")
REF = "bench-v2.8.2"
CEILING_S = 6 * 3600
CASES = {
    "opus-rep2": ("claude-opus-5_5_xhigh-v2", 2, "if_stage.sv", "`ifdef RISCV_FORMAL"),
    "sonnet55-rep5": ("claude-sonnet-5-5_xhigh-v2", 5, "reg_file.sv", "`ifdef RISCV_FORMAL"),
}
PATH = "/opt/hwe-toolchain/oss-cad-suite/bin:" + os.environ["PATH"]


def keep_else_arm(text: str, opener: str) -> str:
    """Replace the first `opener` ... `endif block (no nesting inside) by
    the body of its final `else arm."""
    lines = text.splitlines(keepends=True)
    i = next(n for n, l in enumerate(lines) if l.strip() == opener)
    depth, else_at, end = 0, None, None
    for n in range(i, len(lines)):
        s = lines[n].strip()
        if s.startswith(("`ifdef", "`ifndef")):
            depth += 1
        elif s.startswith("`endif"):
            depth -= 1
            if depth == 0:
                end = n
                break
        elif depth == 1 and s.startswith("`else"):
            else_at = n
    if else_at is None or end is None:
        raise SystemExit(f"no `else arm for {opener}")
    return "".join(lines[:i] + lines[else_at + 1:end] + lines[end + 1:])


def setup(case: str, control: bool) -> Path:
    model, rep, fname, opener = CASES[case]
    tree = Path.home() / "a12step2" / (case + ("-control" if control else ""))
    if tree.exists():
        shutil.rmtree(tree)
    tree.mkdir(parents=True)
    arch = subprocess.run(["git", "-C", str(REPO), "archive", REF], capture_output=True, check=True).stdout
    subprocess.run(["tar", "-x", "-C", str(tree)], input=arch, check=True)
    shutil.copytree(REPO / "formal/riscv-formal", tree / "formal/riscv-formal", symlinks=True)
    shutil.rmtree(tree / "formal/riscv-formal/cores", ignore_errors=True)
    rtl = tree / "cores/bench/rtl"
    shutil.rmtree(rtl)
    shutil.copytree(REPO / "bench/v2" / model / f"rep{rep}" / "final-rtl", rtl)
    if not control:
        f = rtl / fname
        before = f.read_text()
        after = keep_else_arm(before, opener)
        f.write_text(after)
        (tree / "step2_patch.diff").write_text(subprocess.run(
            ["diff", "-u", "--label", f"final-rtl/{fname}", "--label", f"step2/{fname}", "-", str(f)],
            input=before, capture_output=True, text=True).stdout)
    return tree


def run(tree: Path, jobs: int) -> dict:
    env = {**os.environ, "PATH": PATH, "RTL_DIR": "cores/bench/rtl", "CORE_NAME": "bench",
           "WRAPPER": str(tree / "formal/wrapper_si.sv"), "CHECKS_CFG": str(tree / "formal/checks_si.cfg"),
           "FORMAL_WORK_ID": "step2", "JOBS": str(jobs)}
    log = open(tree / "step2_run_all.log", "w")
    t0 = time.time()
    p = subprocess.Popen(["bash", "formal/run_all.sh"], cwd=tree, env=env, stdout=log,
                         stderr=subprocess.STDOUT, start_new_session=True)
    try:
        rc = p.wait(timeout=CEILING_S)
        finished = True
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
        rc, finished = None, False
    log.close()
    out = (tree / "step2_run_all.log").read_text()
    m = re.search(r"Formal: (\d+) passed, (\d+) failed", out)
    failed = re.search(r"Failed: (.*)", out)
    res = {"tree": str(tree), "rc": rc, "finished": finished, "elapsed_s": round(time.time() - t0),
           "passed": int(m.group(1)) if m else None, "failed": int(m.group(2)) if m else None,
           "failed_checks": failed.group(1).split() if failed else []}
    res["verdict"] = ("not finished" if not finished else
                      "pass" if m and res["failed"] == 0 and res["passed"] >= 50 and rc == 0 else "fail")
    return res


def main(argv):
    case = argv[0]
    control = "--control" in argv
    jobs = int(argv[argv.index("--jobs") + 1]) if "--jobs" in argv else 8
    tree = setup(case, control)
    res = {"case": case, "control": control, "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           **run(tree, jobs)}
    (tree / "step2_result.json").write_text(json.dumps(res, indent=1))
    print(json.dumps(res))


if __name__ == "__main__":
    main(sys.argv[1:])
