"""Shared cocotb constants and runner helpers for cores/v1 unit tests.

Constants mirror rtl/core_pkg.sv. If a localparam there changes, change
the matching value here.
"""
from __future__ import annotations

import os
from pathlib import Path

# cocotb 2.x moved the runner from cocotb.runner to cocotb_tools.runner.
from cocotb_tools.runner import get_runner

# ── ALU encodings (rtl/core_pkg.sv) ────────────────────────────────────────
# RV32I ops use op[4]=0:
ALU_ADD    = 0
ALU_SUB    = 1
ALU_AND    = 2
ALU_OR     = 3
ALU_XOR    = 4
ALU_SLT    = 5
ALU_SLTU   = 6
ALU_SLL    = 7
ALU_SRL    = 8
ALU_SRA    = 9
ALU_LUI    = 10
# RV32M ops use op[4]=1 and op[2:0]=funct3:
ALU_MUL    = 0b10000  # 16
ALU_MULH   = 0b10001  # 17
ALU_MULHSU = 0b10010  # 18
ALU_MULHU  = 0b10011  # 19
ALU_DIV    = 0b10100  # 20
ALU_DIVU   = 0b10101  # 21
ALU_REM    = 0b10110  # 22
ALU_REMU   = 0b10111  # 23

# ── BranchOp encodings (= funct3 of BRANCH opcode) ─────────────────────────
BR_BEQ  = 0
BR_BNE  = 1
BR_BLT  = 4
BR_BGE  = 5
BR_BLTU = 6
BR_BGEU = 7

# ── Paths ──────────────────────────────────────────────────────────────────
# __file__ is cores/v1/test/_helpers.py, so:
#   parent   = cores/v1/test/
#   parent.parent = cores/v1/
CORE_DIR  = Path(__file__).resolve().parent.parent
RTL       = CORE_DIR / "rtl"
TEST_DIR  = CORE_DIR / "test"
SIM_BUILD = CORE_DIR / "sim_build"


def run_cocotb(toplevel: str, sources: list[str], test_module: str) -> None:
    """Build the DUT under Verilator and run the given cocotb test_module.

    `sources` is a list of bare filenames under rtl/. Order matters —
    package files (e.g. core_pkg.sv) come first.
    """
    sim = os.environ.get("SIM", "verilator")
    runner = get_runner(sim)
    build_dir = SIM_BUILD / toplevel

    runner.build(
        sources=[str(RTL / s) for s in sources],
        hdl_toplevel=toplevel,
        build_dir=str(build_dir),
        always=True,
        build_args=["-Wall", "-Wno-fatal", "-Wno-style"],
    )
    runner.test(
        hdl_toplevel=toplevel,
        test_module=test_module,
        test_dir=str(TEST_DIR),
        build_dir=str(build_dir),
    )
