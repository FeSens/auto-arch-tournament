"""Vendor place-and-route and timing for the FPGA fitness (HWE Bench V2).

V2 times designs with Gowin EDA (the FPGA vendor's own synthesis, place and
route and static timing analysis) instead of Yosys + nextpnr. nextpnr's
timing model for this part misses whole classes of paths: a single-cycle
32-bit divider that Gowin times at 6.9 MHz (133 logic levels) is reported
at 122.6 MHz, and V1's best design (48.9 MHz under Gowin) at ~240 MHz
(research/v2/NOTES.md, 2026-09-28). The vendor flow is also insensitive to
circuit-neutral netlist changes that moved nextpnr's Fmax by 10-40%
(research/runs/EXP-2026-09-28-gowin-pilot).

Fmax is the median over Gowin's placement algorithms (PLACE_OPTIONS), each
a full build of the same RTL; results are deterministic for a given input.
"""
from __future__ import annotations

import asyncio
import os
import re
import shutil
import statistics
from pathlib import Path

GOWIN_HOME = Path(os.environ.get("GOWIN_HOME", "/opt/gowin"))
GOWIN_VERSION = "1.9.11.03 Education"
PART = "GW2AR-LV18QN88C8/I7"      # Tang Nano 20K
DEVICE_VERSION = "C"
PLACE_OPTIONS = (0, 1, 2)
CST = "fpga/constraints/Tang_Nano_20K.cst"
SDC = "fpga/constraints/clock.sdc"
STALL_GEN = "fpga/bench_stall_gen.sv"
BUILD_TIMEOUT_SEC = 2700


def gowin_env(base: dict | None, workdir: Path) -> dict:
    env = dict(os.environ if base is None else base)
    libs = [GOWIN_HOME / "deps/root/usr/lib/x86_64-linux-gnu", GOWIN_HOME / "IDE/lib"]
    env["LD_LIBRARY_PATH"] = ":".join(map(str, libs))
    env["QT_QPA_PLATFORM"] = "offscreen"
    xdg = workdir / ".xdg"
    xdg.mkdir(parents=True, exist_ok=True)
    os.chmod(xdg, 0o700)
    env["XDG_RUNTIME_DIR"] = str(xdg)
    return env


def rtl_sources(rtl_dir: Path) -> list[Path]:
    srcs = sorted(rtl_dir.glob("*.sv"))
    pkg = rtl_dir / "core_pkg.sv"
    return ([pkg] if pkg in srcs else []) + [p for p in srcs if p != pkg]


def project_tcl(worktree: Path, rtl_dir: Path, bench_sv: str, place_option: int) -> str:
    files = [*rtl_sources(rtl_dir), worktree / STALL_GEN, worktree / bench_sv,
             worktree / CST, worktree / SDC]
    return "\n".join([
        f"set_device {PART} -device_version {DEVICE_VERSION}",
        *(f"add_file {f}" for f in files),
        "set_option -top_module core_bench",
        "set_option -verilog_std sysv2017",
        "set_option -output_base_name core_bench",
        f"set_option -place_option {place_option}",
        "set_option -gen_text_timing_rpt 1",
        "run all",
        "",
    ])


_MAXF = re.compile(r"^\s*\d+\s+\S+\s+[\d.]+\(MHz\)\s+([\d.]+)\(MHz\)\s+(\d+)", re.M)


def _cells(rpt: str, name: str) -> int | None:
    m = re.search(rf"^\s*{re.escape(name)}\s*\|\s*(\d+)", rpt, re.M)
    return int(m.group(1)) if m else None


def critical_paths(tr_text: str, n: int = 5) -> list[dict]:
    """The n worst setup paths: endpoints, delay, logic cells and the
    modules the path crosses (in order), from Gowin's timing report."""
    # The headings also appear, indented, in the report's table of contents.
    m = re.search(r"^3\.3\.1 Setup Analysis Report", tr_text, re.M)
    if not m:
        return []
    sec = tr_text[m.end():]
    h = re.search(r"^3\.3\.2 Hold Analysis Report", sec, re.M)
    sec = sec[:h.start()] if h else sec
    out = []
    for block in re.split(r"^\s*Path\d+\s*$", sec, flags=re.M)[1:n + 1]:
        def field(name):
            m = re.search(rf"^{name}\s*:\s*(.+)$", block, re.M)
            return m.group(1).strip() if m else None
        arrival = block.split("Data Arrival Path:")[-1].split("Data Required Path:")[0]
        cells = [l.split()[-1] for l in arrival.splitlines() if " tINS " in f" {l} "]
        mods = []
        for c in cells:
            m = "/".join(c.split("/")[:-2]) or c.split("/")[0]
            if not mods or mods[-1] != m:
                mods.append(m)
        out.append({"from": field("From"), "to": field("To"),
                    "slack_ns": float(field("Slack")) if field("Slack") else None,
                    "arrival_ns": float(field("Data Arrival Time")) if field("Data Arrival Time") else None,
                    "logic_cells": len(cells), "modules": mods})
    return out


def parse_reports(outdir: Path) -> dict:
    """Fmax and area from a finished build, or {'placement_failed': True}."""
    tr = outdir / "impl/pnr/core_bench.tr"
    rpt = outdir / "impl/pnr/core_bench.rpt.txt"
    if not (tr.is_file() and rpt.is_file()):
        return {"placement_failed": True, "fmax_mhz": None}
    t, r = tr.read_text(errors="replace"), rpt.read_text(errors="replace")
    head = t[t.find("Max Frequency Summary", t.find("2.3 Max Frequency")):]
    m = _MAXF.search(head)
    if not m:
        return {"placement_failed": True, "fmax_mhz": None, "reason": "no Fmax in timing report"}
    return {
        "placement_failed": False,
        "fmax_mhz": float(m.group(1)),
        "levels": int(m.group(2)),
        "logic": _cells(r, "Logic"),
        "regs": _cells(r, "Register"),
        "lutram": _cells(r, "--SSRAM(RAM16)") or 0,
        "bsram": _cells(r, "BSRAM") or 0,
        "dsp": _cells(r, "DSP") or 0,
        "critical_paths": critical_paths(t),
    }


async def build(worktree: str | Path, rtl_dir: str | Path, bench_sv: str,
                place_option: int, outdir: str | Path, env: dict | None = None) -> dict:
    worktree, rtl_dir, outdir = Path(worktree).resolve(), Path(rtl_dir).resolve(), Path(outdir).resolve()
    shutil.rmtree(outdir, ignore_errors=True)
    outdir.mkdir(parents=True)
    (outdir / "build.tcl").write_text(project_tcl(worktree, rtl_dir, bench_sv, place_option))
    log = outdir / "gw.log"
    with log.open("w") as f:
        proc = await asyncio.create_subprocess_exec(
            str(GOWIN_HOME / "IDE/bin/gw_sh"), "build.tcl", cwd=outdir,
            stdout=f, stderr=asyncio.subprocess.STDOUT,
            env=gowin_env(env, outdir), start_new_session=True)
        try:
            await asyncio.wait_for(proc.wait(), timeout=BUILD_TIMEOUT_SEC)
        except asyncio.TimeoutError:
            try:
                os.killpg(proc.pid, 9)
            except ProcessLookupError:
                pass
            await proc.wait()
            return {"place_option": place_option, "placement_failed": True,
                    "fmax_mhz": None, "timed_out": True,
                    "reason": f"Gowin build timeout after {BUILD_TIMEOUT_SEC}s"}
    res = parse_reports(outdir)
    if res["placement_failed"]:
        errs = [l for l in log.read_text(errors="replace").splitlines() if "ERROR" in l]
        res["reason"] = res.get("reason") or ("; ".join(errs[:3])[:500] or "no reports written")
    return {"place_option": place_option, **res}


async def build_all(worktree, rtl_dir, bench_sv, gen_dir, env=None,
                    options=PLACE_OPTIONS) -> list[dict]:
    return await asyncio.gather(*(
        build(worktree, rtl_dir, bench_sv, p, Path(gen_dir) / f"gowin_p{p}", env)
        for p in options))


def summarize(results: list[dict]) -> dict:
    """Median Fmax over placement options; every option must fit (the flow
    is deterministic, so a failure is a property of the design)."""
    failed = [r for r in results if r["placement_failed"]]
    if failed:
        return {"placement_failed": True,
                "seeds": [r.get("fmax_mhz") for r in results],
                "reason": failed[0].get("reason")}
    ref = next(r for r in results if r["place_option"] == PLACE_OPTIONS[0])
    return {
        "placement_failed": False,
        "fmax_mhz": round(statistics.median(r["fmax_mhz"] for r in results), 3),
        "seeds": [r["fmax_mhz"] for r in results],
        "perturbations": [[r["place_option"], r["fmax_mhz"], r["levels"]] for r in results],
        "lut4": ref["logic"], "ff": ref["regs"], "lutram": ref["lutram"],
        "bsram": ref["bsram"], "dsp": ref["dsp"], "logic_levels": ref["levels"],
        "critical_path": (ref.get("critical_paths") or [None])[0],
    }


def main(argv=None) -> int:
    """`make timing TARGET=<core>`: the vendor timing the evaluator scores,
    with the worst paths, for agents' own checks."""
    import argparse, json
    from tools.eval.fpga import _bench_sv
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("--worktree", default=".")
    ap.add_argument("--paths", type=int, default=5)
    ap.add_argument("--all-options", action="store_true",
                    help="build every placement option the evaluator uses (default: option 0 only)")
    a = ap.parse_args(argv)
    wt = Path(a.worktree).resolve()
    opts = PLACE_OPTIONS if a.all_options else PLACE_OPTIONS[:1]
    res = asyncio.run(build_all(wt, wt / "cores" / a.target / "rtl", _bench_sv(str(wt), a.target),
                                wt / "cores" / a.target / "generated" / "timing", options=opts))
    for r in res:
        if r["placement_failed"]:
            print(f"place_option {r['place_option']}: FAILED ({r.get('reason')})")
            continue
        print(f"place_option {r['place_option']}: Fmax {r['fmax_mhz']} MHz, {r['levels']} logic levels; "
              f"logic {r['logic']}, registers {r['regs']}, LUT-RAM {r['lutram']}, BSRAM {r['bsram']}, DSP {r['dsp']}")
        tr = (wt / "cores" / a.target / "generated" / "timing" / f"gowin_p{r['place_option']}" / "impl/pnr/core_bench.tr")
        for i, p in enumerate(critical_paths(tr.read_text(errors="replace"), a.paths), 1):
            print(f"  path {i}: {p['arrival_ns']} ns, {p['logic_cells']} cells, {p['from']} -> {p['to']}")
            print(f"          through: {' > '.join(p['modules'])}")
        print(f"  full report: {tr}")
    if len(res) > 1 and all(not r["placement_failed"] for r in res):
        print(f"score Fmax (median): {summarize(res)['fmax_mhz']} MHz")
    return 0 if all(not r["placement_failed"] for r in res) else 1


if __name__ == "__main__":
    raise SystemExit(main())
