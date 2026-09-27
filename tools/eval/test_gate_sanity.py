"""Gate sanity check (V2): replaces V1's static and random-mutation runs.

The unchanged starting core must pass the full-trace co-simulation, and
three planted bugs must each be rejected by it. Two of them (DIVU by zero,
DIV INT_MIN / -1) passed every V1 gate: selftest, CoreMark CRCs, and
ALTOPS formal, which abstracts division.

Slow (builds four Verilator simulators): runs only with HWE_SLOW=1, and is
part of the pre-launch checklist in research/v2/PLAN.md.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
TOOLCHAIN = [REPO / ".toolchain" / "oss-cad-suite" / "bin", REPO / ".toolchain" / "bin"]
TRACE_ELFS = ["selftest", "random1", "random2", "random3"]

pytestmark = pytest.mark.skipif(os.environ.get("HWE_SLOW") != "1",
                                reason="slow: set HWE_SLOW=1")

BUGS = {
    "divu_by_zero": ("alu.sv",
                     "ALU_DIVU: out = (b == 32'b0) ? 32'hFFFFFFFF : (a / b);",
                     "ALU_DIVU: out = (b == 32'b0) ? 32'h0 : (a / b);"),
    "div_overflow": ("alu.sv", None, None),  # applied by _div_overflow_bug
    "rs2_forwarding": ("forward_unit.sv",
                       "    else if (mem_wb_w_en && mem_wb_rd != 5'b0 && mem_wb_rd == id_ex_rs2) fwd_rs2 = 2'd2;\n",
                       ""),
}


def _env() -> dict:
    env = os.environ.copy()
    env["PATH"] = os.pathsep.join([*map(str, TOOLCHAIN), env["PATH"]])
    return env


def _v0_rtl(dest: Path) -> Path:
    subprocess.run(f"git -C {REPO} archive bench-v2 cores/bench/rtl | tar -x -C {dest}",
                   shell=True, check=True)
    return dest / "cores" / "bench" / "rtl"


def _div_overflow_bug(rtl: Path) -> None:
    p = rtl / "alu.sv"
    s = p.read_text()
    i = s.index("ALU_DIV: begin")
    j = s.index("else if (a == 32'h80000000 && b == 32'hFFFFFFFF)", i)
    k = s.index("out =", j)
    e = s.index(";", k)
    p.write_text(s[:k] + "out = 32'h0" + s[e:])


def _build(rtl: Path, obj: Path) -> Path:
    r = subprocess.run(["bash", str(REPO / "test/cosim/build.sh")], capture_output=True, text=True,
                       env={**_env(), "RTL_DIR": str(rtl), "OBJ_DIR": str(obj), "NRET": "1"})
    assert r.returncode == 0, r.stderr[-2000:]
    return obj / "cosim_sim"


def _trace_passes(sim: Path) -> bool:
    for elf in TRACE_ELFS:
        for flags in ([], ["--istall", "--dstall"]):
            r = subprocess.run([sys.executable, str(REPO / "test/cosim/run_cosim.py"), str(sim),
                                str(REPO / f"bench/programs/{elf}.elf"), *flags],
                               capture_output=True, text=True, timeout=300)
            if r.returncode != 0:
                return False
    return True


@pytest.fixture(scope="module")
def elfs():
    r = subprocess.run(["make", "-f", "bench/programs/Makefile", "all"], cwd=REPO,
                       capture_output=True, text=True, env=_env())
    assert r.returncode == 0, r.stderr[-2000:]


def test_v0_passes_full_trace(elfs, tmp_path):
    assert _trace_passes(_build(_v0_rtl(tmp_path), tmp_path / "obj"))


@pytest.mark.parametrize("bug", sorted(BUGS))
def test_planted_bug_is_rejected(elfs, tmp_path, bug):
    rtl = _v0_rtl(tmp_path)
    if bug == "div_overflow":
        _div_overflow_bug(rtl)
    else:
        f, old, new = BUGS[bug]
        s = (rtl / f).read_text()
        assert s.count(old) == 1
        (rtl / f).write_text(s.replace(old, new))
    assert not _trace_passes(_build(rtl, tmp_path / "obj"))
