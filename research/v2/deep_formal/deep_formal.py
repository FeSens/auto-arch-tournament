#!/usr/bin/env python3
"""Deep formal (no RISCV_FORMAL_ALTOPS) on V2 final designs: the riscv-formal
instruction checks of the eight RV32M instructions with the real multiplier
and divider, which the per-round gate replaces with stand-in formulas.

For each design a scratch tree is made from the harness fixture
(`git archive hwe-bench-v2.8.4`, with a private copy of formal/riscv-formal so
the shared checkout is never written) and the design's final RTL replaces
cores/bench/rtl. The checks config is formal/checks_si.cfg (the gate's
single-issue config) without the ALTOPS define, filtered to
insn_{mul,mulh,mulhsu,mulhu,div,divu,rem,remu}_ch0, with the insn BMC depth
given by --depth. formal/run_all.sh runs it, as the gate does.

Spec fix (applied in the private copy only): at the vendored riscv-formal
commit (2aa7b49), insns/insn_div.v and insn_rem.v compute the signed result as
`cond ? <unsigned> : cond2 ? <unsigned> : $signed(a) / $signed(b)`. Verilog
makes a conditional with an unsigned arm unsigned and propagates that into the
context-determined operands, so the division (and the remainder) is evaluated
UNSIGNED (Yosys: DIV 0xffd47ff1, 0xad8887ff gives 1; the RV32M answer is 0).
With that spec every correct divider fails insn_div/insn_rem on negative
operands. The private copy wraps the signed operation in $unsigned(...), which
makes it self-determined and signed (the same expression gives 0). DIVU/REMU and
the MUL family are written without the problem and are unchanged.

A check's outcome is read from its SBY log: PASS, FAIL (a counterexample:
the real arithmetic disagrees with the spec), PREUNSAT (no trace retires the
instruction at the check cycle within the depth, so the check is vacuous;
an iterative divider needs a depth beyond its latency), or TIMEOUT.

    python3 -B research/v2/deep_formal/deep_formal.py NAME RTL_DIR [--depth 20] [--jobs 8]
        [--timeout 14400] [--only div,divu,rem,remu]

Writes research/v2/deep_formal/results/<NAME>-d<depth>[-<only>].json.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
TAG = "hwe-bench-v2.8.4"
WORK = Path("/home/bench/deepformal")
OUT = Path(__file__).resolve().parent / "results"
MEXT = ("mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu")


def make_tree(name: str, rtl_dir: Path) -> Path:
    tree = WORK / name
    if tree.exists():
        shutil.rmtree(tree)
    tree.mkdir(parents=True)
    archive = subprocess.run(["git", "-C", str(REPO), "archive", TAG], check=True,
                             capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", str(tree)], input=archive, check=True)
    shutil.copytree(REPO / "formal/riscv-formal", tree / "formal/riscv-formal", symlinks=True,
                    ignore=lambda d, names: names if Path(d).name == "cores" else [])
    rtl = tree / "cores/bench/rtl"
    shutil.rmtree(rtl)
    rtl.mkdir()
    for f in sorted(rtl_dir.glob("*.sv")):
        shutil.copy(f, rtl / f.name)
    return tree


SPEC_FIX = {"insn_div.v": ("$signed(rvfi_rs1_rdata) / $signed(rvfi_rs2_rdata);",
                           "$unsigned($signed(rvfi_rs1_rdata) / $signed(rvfi_rs2_rdata));"),
            "insn_rem.v": ("$signed(rvfi_rs1_rdata) % $signed(rvfi_rs2_rdata);",
                           "$unsigned($signed(rvfi_rs1_rdata) % $signed(rvfi_rs2_rdata));")}


def fix_spec(tree: Path) -> None:
    for name, (old, new) in SPEC_FIX.items():
        f = tree / "formal/riscv-formal/insns" / name
        t = f.read_text()
        assert t.count(old) == 1, name
        f.write_text(t.replace(old, new))


def write_cfg(tree: Path, depth: int, insns=MEXT) -> Path:
    cfg = (tree / "formal/checks_si.cfg").read_text()
    assert "`define RISCV_FORMAL_ALTOPS\n" in cfg
    cfg = cfg.replace("`define RISCV_FORMAL_ALTOPS\n", "")
    cfg = re.sub(r"(?m)^insn\s+\d+\s*$", f"insn          {depth}", cfg)
    filt = "[filter-checks]\n" + "".join(f"+ insn_{i}_ch0\n" for i in insns) + "- .*\n\n"
    cfg = cfg.replace("[depth]", filt + "[depth]", 1)
    path = tree / "formal/checks-deep-mext.cfg"
    path.write_text(cfg)
    return path


def outcome(log: Path) -> str:
    if not log.exists():
        return "MISSING"
    t = log.read_text(errors="replace")
    if "DONE (PASS" in t:
        return "PASS"
    if "Status: PREUNSAT" in t:
        return "PREUNSAT"
    if "DONE (FAIL" in t or "Status: failed" in t:
        return "FAIL"
    return "UNKNOWN"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("name")
    ap.add_argument("rtl_dir", type=Path)
    ap.add_argument("--depth", type=int, default=20)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=14400)
    ap.add_argument("--only", default="", help="comma-separated subset of " + ",".join(MEXT))
    args = ap.parse_args()
    insns = tuple(args.only.split(",")) if args.only else MEXT
    assert all(i in MEXT for i in insns), insns
    tag = f"{args.name}-d{args.depth}" + (f"-{'-'.join(insns)}" if args.only else "")
    rtl_dir = args.rtl_dir if args.rtl_dir.is_absolute() else REPO / args.rtl_dir
    tree = make_tree(tag, rtl_dir)
    fix_spec(tree)
    cfg = write_cfg(tree, args.depth, insns)
    env = {**os.environ, "RTL_DIR": "cores/bench/rtl", "CORE_NAME": "bench",
           "WRAPPER": "formal/wrapper_si.sv", "CHECKS_CFG": str(cfg.relative_to(tree)),
           "JOBS": str(args.jobs), "FORMAL_WORK_ID": "deep"}
    rec = {"design": args.name, "rtl_dir": str(args.rtl_dir), "fixture": TAG, "depth": args.depth,
           "spec_fix": {k: v[1] for k, v in SPEC_FIX.items()},
           "started": datetime.now(timezone.utc).isoformat()}
    t0 = time.time()
    # Own process group, so a timeout takes make, SBY and the solvers down too.
    p = subprocess.Popen(["nice", "-n", "19", "bash", "formal/run_all.sh", str(cfg.relative_to(tree))],
                         cwd=tree, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=args.timeout)
        rec["run_all_rc"] = p.returncode
        rec["tail"] = out[-1500:]
        timed_out = False
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
    rec["seconds"] = round(time.time() - t0)
    checks = tree / "formal/riscv-formal/cores/bench-deep/checks"
    rec["checks"] = {}
    for i in insns:
        name = f"insn_{i}_ch0"
        o = outcome(checks / name / "logfile.txt")
        if timed_out and o in ("MISSING", "UNKNOWN"):
            o = "TIMEOUT"
        el = re.search(r"Elapsed clock time \[H:MM:SS \(secs\)\]: \S+ \((\d+)\)",
                       (checks / name / "logfile.txt").read_text(errors="replace")) \
            if (checks / name / "logfile.txt").exists() else None
        rec["checks"][name] = {"outcome": o, "seconds": int(el.group(1)) if el else None}
    rec["ended"] = datetime.now(timezone.utc).isoformat()
    OUT.mkdir(exist_ok=True)
    (OUT / f"{tag}.json").write_text(json.dumps(rec, indent=1) + "\n")
    print(args.name, args.depth, {k: v["outcome"] for k, v in rec["checks"].items()}, rec["seconds"], "s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
