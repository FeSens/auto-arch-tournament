"""Remote job runner for the cross-FPGA study (amendment 15, part C).

Runs on the Vivado host (omarchy) inside ~/hwe-xfpga. xfpga.py (on the bench
host) pushes designs/<name>/{manifest.json, root/...}, this file and flow.tcl,
then starts:

    nice -n 10 python3 runner.py [--jobs 6] [--pass1-only] [--force] NAME...

Per design (amendment 15 part C flow):
  pass 1: synth at 5.000 ns, one build with place_design -directive Default,
          F1 = 1000 / (5.000 - WNS).
  pass 2: re-synthesize at P2 = round(0.95 * 1000 / F1, 3) ns, then three
          builds from that checkpoint, directives Default, Explore and
          ExtraTimingOpt. Fmax = median of the three. Area from the pass 2
          Default build.
A Vivado error in synthesis, placement or routing is a transfer failure: the
error lines are recorded and nothing is retried or edited.

At most --jobs Vivado processes run at once (each with maxThreads 2). Each
design's .dcp checkpoints are deleted once its reports are parsed. Results:
runs/<name>/design.json (plus the per-job reports in runs/<name>/<job>/).
A design whose design.json is complete for the same source hash is skipped.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
VIVADO = os.environ.get("XFPGA_VIVADO", str(Path.home() / ".local/bin/vivado"))
PART = "xc7a200tsbg484-1"
P1_PERIOD = 5.000
P1_DIRECTIVE = "Default"
P2_DIRECTIVES = ("Default", "Explore", "ExtraTimingOpt")
JOB_TIMEOUT_SEC = 4 * 3600
LOCK = threading.Lock()
SLOTS: threading.Semaphore


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg: str) -> None:
    with LOCK:
        print(f"{now()} {msg}", flush=True)


def tcl_list(items) -> str:
    return "[list " + " ".join("{" + str(i) + "}" for i in items) + "]"


def parse_tsv(path: Path) -> dict:
    out: dict = {}
    if not path.exists():
        return out
    for line in path.read_text(errors="replace").splitlines():
        if "\t" in line:
            k, v = line.split("\t", 1)
            out[k] = v
    for k in list(out):
        if k.startswith("sec_") or k in ("wns", "wns_all_groups", "whs", "period", "requirement",
                                           "datapath_delay", "logic_delay", "net_delay", "skew",
                                           "uncertainty"):
            try:
                out[k] = float(out[k])
            except ValueError:
                pass
        elif k == "logic_levels":
            try:
                out[k] = int(out[k])
            except ValueError:
                pass
    return out


def error_lines(log_path: Path, limit: int = 20) -> list[str]:
    if not log_path.exists():
        return []
    lines = [l.strip() for l in log_path.read_text(errors="replace").splitlines()
             if l.startswith("ERROR:") or l.startswith("CRITICAL WARNING:")]
    errs = [l for l in lines if l.startswith("ERROR:")]
    return (errs or lines)[:limit]


def count_lines(log_path: Path, prefix: str) -> int:
    if not log_path.exists():
        return 0
    return sum(1 for l in log_path.read_text(errors="replace").splitlines() if l.startswith(prefix))


def run_vivado(job_dir: Path, header: str) -> dict:
    job_dir.mkdir(parents=True, exist_ok=True)
    for stale in ("result.tsv", "vivado.log"):
        (job_dir / stale).unlink(missing_ok=True)
    (job_dir / "job.tcl").write_text(header + f"source {{{ROOT / 'flow.tcl'}}}\n")
    cmd = [VIVADO, "-mode", "batch", "-nojournal", "-log", str(job_dir / "vivado.log"),
           "-source", str(job_dir / "job.tcl")]
    with SLOTS:
        t = time.monotonic()
        log(f"start {job_dir.relative_to(ROOT)}")
        try:
            with open(job_dir / "stdout.txt", "w") as so:
                rc = subprocess.run(cmd, cwd=job_dir, stdout=so, stderr=subprocess.STDOUT,
                                    timeout=JOB_TIMEOUT_SEC).returncode
            timed_out = False
        except subprocess.TimeoutExpired:
            rc, timed_out = None, True
        wall = round(time.monotonic() - t, 1)
    res = parse_tsv(job_dir / "result.tsv")
    res["wall_sec"] = wall
    res["returncode"] = rc
    res["warnings"] = count_lines(job_dir / "vivado.log", "WARNING:")
    res["critical_warnings"] = count_lines(job_dir / "vivado.log", "CRITICAL WARNING:")
    if timed_out:
        res["status"] = "timeout"
    elif "status" not in res:
        res["status"] = "vivado_failed"
    if res["status"] != "ok":
        res["error_lines"] = error_lines(job_dir / "vivado.log")
    log(f"done  {job_dir.relative_to(ROOT)} status={res['status']} wall={wall}s"
        + (f" wns={res.get('wns')}" if "wns" in res else ""))
    return res


def synth(name: str, man: dict, job: str, period: float) -> dict:
    d = ROOT / "designs" / name
    srcs = [[f["lang"], f.get("lib") or "", str(d / f["path"])] for f in man["files"]]
    header = "".join([
        "set MODE synth\n",
        f"set OUT {{{ROOT / 'runs' / name / job}}}\n",
        f"set PART {PART}\n",
        f"set TOP {man['top']}\n",
        f"set PERIOD {period:.3f}\n",
        "set SOURCES [list " + " ".join("{" + " ".join("{" + x + "}" for x in s) + "}" for s in srcs)
        + "]\n",
        f"set INCLUDE_DIRS {tcl_list(str(d / i) for i in man.get('include_dirs', []))}\n",
    ])
    return run_vivado(ROOT / "runs" / name / job, header)


def impl(name: str, synth_job: str, job: str, directive: str) -> dict:
    header = "".join([
        "set MODE impl\n",
        f"set OUT {{{ROOT / 'runs' / name / job}}}\n",
        f"set PART {PART}\n",
        f"set SYNTH_DCP {{{ROOT / 'runs' / name / synth_job / 'synth.dcp'}}}\n",
        f"set DIRECTIVE {directive}\n",
    ])
    res = run_vivado(ROOT / "runs" / name / job, header)
    if res["status"] == "ok":
        res["fmax_mhz"] = round(1000.0 / (res["period"] - res["wns"]), 3)
    return res


UTIL_ROWS = {
    "slice_luts": r"Slice LUTs\*?",
    "lut_as_logic": r"LUT as Logic",
    "lut_as_memory": r"LUT as Memory",
    "slice_registers": r"Slice Registers",
    "f7_muxes": r"F7 Muxes",
    "f8_muxes": r"F8 Muxes",
    "block_ram_tile": r"Block RAM Tile",
    "dsps": r"DSPs",
    "slices": r"Slice",
}


def parse_util(path: Path) -> dict:
    if not path.exists():
        return {}
    text = path.read_text(errors="replace")
    out = {}
    for key, pat in UTIL_ROWS.items():
        m = re.search(rf"^\|\s*{pat}\s*\|\s*([\d.]+)\s*\|", text, re.M)
        if m:
            v = float(m.group(1))
            out[key] = int(v) if v.is_integer() else v
    # Distributed RAM vs shift registers inside LUT as Memory.
    m = re.search(r"^\|\s*LUT as Distributed RAM\s*\|\s*(\d+)", text, re.M)
    if m:
        out["lut_as_distributed_ram"] = int(m.group(1))
    m = re.search(r"^\|\s*LUT as Shift Register\s*\|\s*(\d+)", text, re.M)
    if m:
        out["lut_as_shift_register"] = int(m.group(1))
    return out


def parse_util_hier(path: Path) -> list[dict]:
    """Rows of report_utilization -hierarchical: instance, module and the
    numeric columns, keyed by the header names."""
    if not path.exists():
        return []
    rows, header = [], None
    for line in path.read_text(errors="replace").splitlines():
        if not line.startswith("|"):
            continue
        cells = [c for c in line.strip().strip("|").split("|")]
        if header is None and "Instance" in cells[0]:
            header = [c.strip() for c in cells]
            continue
        if header is None or len(cells) != len(header):
            continue
        inst = cells[0].rstrip()
        depth = (len(inst) - len(inst.lstrip())) // 2
        row = {"instance": inst.strip(), "depth": depth}
        for h, c in zip(header[1:], cells[1:]):
            c = c.strip()
            try:
                row[h] = int(c)
            except ValueError:
                row[h] = c
        rows.append(row)
    return rows


def route_errors(path: Path) -> int | None:
    if not path.exists():
        return None
    m = re.search(r"# of nets with routing errors\.*\s*:\s*(\d+)", path.read_text(errors="replace"))
    return int(m.group(1)) if m else None


def build_summary(res: dict, job_dir: Path) -> dict:
    keep = ("status", "directive", "period", "wns", "fmax_mhz", "logic_levels", "startpoint",
            "endpoint", "requirement", "datapath_delay", "logic_delay", "net_delay", "skew",
            "uncertainty", "wns_all_groups", "worst_group_all", "whs", "hd_clk_src",
            "sec_open", "sec_opt", "sec_place", "sec_physopt", "sec_route", "wall_sec",
            "warnings", "critical_warnings", "error", "error_lines", "vivado_version")
    out = {k: res[k] for k in keep if k in res}
    out["route_nets_with_errors"] = route_errors(job_dir / "route_status.rpt")
    return out


def run_design(name: str, pass1_only: bool, force: bool) -> None:
    d = ROOT / "designs" / name
    man = json.loads((d / "manifest.json").read_text())
    rd = ROOT / "runs" / name
    out_path = rd / "design.json"
    if out_path.exists() and not force:
        prev = json.loads(out_path.read_text())
        done = prev.get("complete") or (pass1_only and prev.get("pass1"))
        if prev.get("source_sha256") == man["source_sha256"] and done:
            log(f"skip  {name} (already {'complete' if prev.get('complete') else 'pass 1'})")
            return
    rd.mkdir(parents=True, exist_ok=True)
    t0 = time.monotonic()
    rec = {"design": name, "group": man.get("group"), "system": man.get("system"),
           "rep": man.get("rep"), "top": man["top"], "part": PART,
           "source_sha256": man["source_sha256"], "n_files": len(man["files"]),
           "started_at": now(), "status": "running", "complete": False}

    def save():
        out_path.write_text(json.dumps(rec, indent=1))

    def fail(stage: str, res: dict):
        rec["status"] = f"transfer_failure:{stage}"
        rec["error"] = res.get("error")
        rec["error_lines"] = res.get("error_lines", [])
        rec["complete"] = True
        rec["finished_at"] = now()
        rec["wall_sec"] = round(time.monotonic() - t0, 1)
        cleanup(rd)
        save()

    # Pass 1
    s1 = synth(name, man, "p1_synth", P1_PERIOD)
    rec["pass1_synth"] = {k: s1.get(k) for k in ("status", "period", "sec_read", "sec_synth",
                                                 "wall_sec", "warnings", "critical_warnings",
                                                 "error", "error_lines", "vivado_version")
                          if k in s1}
    rec["vivado_version"] = s1.get("vivado_version")
    if s1["status"] != "ok":
        return fail("pass1_synth", s1)
    b1 = impl(name, "p1_synth", "p1_Default", P1_DIRECTIVE)
    rec["pass1"] = build_summary(b1, rd / "p1_Default")
    if b1["status"] != "ok":
        return fail("pass1_impl", b1)
    f1 = 1000.0 / (b1["period"] - b1["wns"])
    rec["F1"] = round(f1, 3)
    rec["pass1"]["util"] = parse_util(rd / "p1_Default" / "util.rpt")
    if pass1_only:
        rec["status"] = "pass1_only"
        rec["finished_at"] = now()
        rec["wall_sec"] = round(time.monotonic() - t0, 1)
        cleanup(rd)
        save()
        return
    save()

    # Pass 2
    p2 = round(0.95 * 1000.0 / f1, 3)
    rec["P2"] = p2
    s2 = synth(name, man, "p2_synth", p2)
    rec["pass2_synth"] = {k: s2.get(k) for k in ("status", "period", "sec_read", "sec_synth",
                                                 "wall_sec", "warnings", "critical_warnings",
                                                 "error", "error_lines") if k in s2}
    if s2["status"] != "ok":
        return fail("pass2_synth", s2)
    with ThreadPoolExecutor(max_workers=len(P2_DIRECTIVES)) as ex:
        builds = list(ex.map(lambda dv: (dv, impl(name, "p2_synth", f"p2_{dv}", dv)),
                             P2_DIRECTIVES))
    rec["pass2"] = {dv: build_summary(b, rd / f"p2_{dv}") for dv, b in builds}
    bad = [dv for dv, b in builds if b["status"] != "ok"]
    if bad:
        return fail(f"pass2_impl_{'_'.join(bad)}", dict(builds)[bad[0]])
    fm = [b["fmax_mhz"] for _, b in builds]
    rec["fmax_p2"] = dict(zip(P2_DIRECTIVES, fm))
    rec["fmax_mhz"] = round(statistics.median(fm), 3)
    rec["area"] = parse_util(rd / "p2_Default" / "util.rpt")
    rec["area_hier"] = parse_util_hier(rd / "p2_Default" / "util_hier.rpt")
    rec["status"] = "ok"
    rec["complete"] = True
    rec["finished_at"] = now()
    rec["wall_sec"] = round(time.monotonic() - t0, 1)
    cleanup(rd)
    save()
    log(f"DESIGN {name} F1={rec['F1']} P2={p2} fmax={rec['fmax_mhz']} {rec['fmax_p2']}")


def cleanup(rd: Path) -> None:
    for p in rd.glob("*/*.dcp"):
        p.unlink(missing_ok=True)
    for p in rd.glob("*/.Xil"):
        subprocess.run(["rm", "-rf", str(p)], check=False)


def main() -> None:
    global SLOTS
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=6, help="max concurrent Vivado processes")
    ap.add_argument("--pass1-only", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("designs", nargs="+")
    a = ap.parse_args()
    SLOTS = threading.Semaphore(a.jobs)
    (ROOT / "runner.pid").write_text(str(os.getpid()))
    log(f"runner start pid={os.getpid()} jobs={a.jobs} pass1_only={a.pass1_only} "
        f"designs={len(a.designs)}")

    def guarded(n):
        try:
            run_design(n, a.pass1_only, a.force)
        except Exception as e:  # keep the other designs going
            log(f"EXCEPTION {n}: {e!r}")

    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        list(ex.map(guarded, a.designs))
    log("runner done")
    (ROOT / "runner.pid").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
