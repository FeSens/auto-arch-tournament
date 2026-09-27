"""Toolchain pre-flight and environment fingerprinting for the bench runner.

Motivated by the 2026-07-11 gpt-5_6-sol rep2/rep3 startup failures: two
reps died in seconds with orchestrator exit 1 and no surviving evidence.
A rep costs hours of wall clock; refusing to start against a broken
toolchain and snapshotting the env are both far cheaper than one wasted rep.
"""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
from pathlib import Path

# Every external binary the eval gates shell out to, per grep of
# Makefile, formal/run_all.sh, and fpga/scripts/ (2026-07-15):
# verilator (lint + cosim), yosys (synth), nextpnr-himbaechel (P&R),
# sby + bitwuzla (riscv-formal).
REQUIRED_TOOLS: tuple[str, ...] = (
    "verilator", "yosys", "nextpnr-himbaechel", "sby", "bitwuzla",
)


# Tools whose exact build affects scores: the gate tools plus the RISC-V
# compiler that builds CoreMark and the trace programs.
DIGEST_TOOLS: tuple[str, ...] = REQUIRED_TOOLS + ("riscv32-unknown-elf-gcc",)

HARNESS_VERSION_FILE = Path(__file__).resolve().parents[1] / "HARNESS_VERSION"


def harness_version() -> str:
    try:
        return HARNESS_VERSION_FILE.read_text().strip()
    except OSError:
        return "unknown"


def _sha256(path: str) -> str | None:
    h = hashlib.sha256()
    try:
        with open(os.path.realpath(path), "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    except OSError:
        return None  # unreadable binary: recorded as unknown, never guessed
    return h.hexdigest()


def _version(tool: str) -> str:
    flag = "-V" if tool == "yosys" else "--version"
    try:
        r = subprocess.run([tool, flag], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return (r.stdout or r.stderr).strip().splitlines()[0] if (r.stdout or r.stderr).strip() else ""


def toolchain_identity() -> dict:
    """Version string and binary hash of every score-relevant tool, and one
    digest over all of them. Two rows with the same digest ran the same
    tool builds; a missing tool is recorded as such, never skipped."""
    tools = {}
    for t in DIGEST_TOOLS:
        p = shutil.which(t)
        tools[t] = {"path": p, "version": _version(t) if p else None,
                    "sha256": _sha256(p) if p else None}
    digest = hashlib.sha256(
        "\n".join(f"{t}={tools[t]['sha256']}" for t in DIGEST_TOOLS).encode()
    ).hexdigest()
    return {"tools": tools, "toolchain_digest": digest}


def env_fingerprint() -> dict:
    """Snapshot of PATH, resolved tools, their versions and hashes, for per-rep forensics."""
    ident = toolchain_identity()
    return {
        "path": os.environ.get("PATH", ""),
        "harness_version": harness_version(),
        "tools": {t: v["path"] for t, v in ident["tools"].items()},
        "tool_versions": {t: v["version"] for t, v in ident["tools"].items()},
        "tool_sha256": {t: v["sha256"] for t, v in ident["tools"].items()},
        "toolchain_digest": ident["toolchain_digest"],
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
