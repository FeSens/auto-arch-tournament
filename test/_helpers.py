"""Shared cocotb constants and runner helpers for unit tests.

Constants mirror rtl/core_pkg.sv. If a localparam there changes, change
the matching value here.
"""
from __future__ import annotations

import os
from pathlib import Path

# cocotb 2.x moved the runner from cocotb.runner to cocotb_tools.runner.
from cocotb_tools.runner import get_runner

# ── ALU encodings (rtl/core_pkg.sv) ────────────────────────────────────────
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
ALU_MUL    = 11
ALU_MULH   = 12
ALU_MULHU  = 13
ALU_MULHSU = 14
ALU_DIV    = 15
ALU_DIVU   = 16
ALU_REM    = 17
ALU_REMU   = 18

# ── BranchOp encodings (= funct3 of BRANCH opcode) ─────────────────────────
BR_BEQ  = 0
BR_BNE  = 1
BR_BLT  = 4
BR_BGE  = 5
BR_BLTU = 6
BR_BGEU = 7

# ── Paths ──────────────────────────────────────────────────────────────────
REPO_ROOT = Path(__file__).resolve().parent.parent
RTL       = REPO_ROOT / "rtl"
TEST_DIR  = REPO_ROOT / "test"
SIM_BUILD = REPO_ROOT / "sim_build"


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
