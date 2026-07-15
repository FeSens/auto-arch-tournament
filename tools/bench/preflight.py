"""Toolchain pre-flight and environment fingerprinting for the bench runner.

Motivated by the 2026-07-11 gpt-5_6-sol rep2/rep3 startup failures: two
reps died in seconds with orchestrator exit 1 and no surviving evidence.
A rep costs hours of wall clock; refusing to start against a broken
toolchain and snapshotting the env are both far cheaper than one wasted rep.
"""
from __future__ import annotations

import os
import shutil

# Every external binary the eval gates shell out to, per grep of
# Makefile, formal/run_all.sh, and fpga/scripts/ (2026-07-15):
# verilator (lint + cosim), yosys (synth), nextpnr-himbaechel (P&R),
# sby + bitwuzla (riscv-formal).
REQUIRED_TOOLS: tuple[str, ...] = (
    "verilator", "yosys", "nextpnr-himbaechel", "sby", "bitwuzla",
)


def env_fingerprint() -> dict:
    """Snapshot of PATH and resolved tool paths, for per-rep forensics."""
    return {
        "path": os.environ.get("PATH", ""),
        "tools": {t: shutil.which(t) for t in REQUIRED_TOOLS},
    }


def missing_tools() -> list[str]:
    return [t for t in REQUIRED_TOOLS if shutil.which(t) is None]


def report() -> str:
    lines = ["[preflight] toolchain:"]
    for t in REQUIRED_TOOLS:
        p = shutil.which(t)
        lines.append(f"  {t:20s} {p or 'MISSING'}")
    return "\n".join(lines)


# Motivated by task-7's disk-hygiene audit (2026-07-15): 48 planned reps
# at the pre-cleanup ~6 GB/rep residue rate is ~300 GB, which is what the
# author hit. Even after CoW clones + SBY workdir cleanup shrink per-rep
# residue to a few hundred MB, a rep that starts with too little headroom
# can still wedge mid-run (e.g. yosys/bitwuzla scratch files, cocotb
# sim_build/ dirs). Refuse to start rather than fail hours in.
MIN_FREE_GB = 30


def free_disk_gb(path: str = ".") -> float:
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize / 1e9
