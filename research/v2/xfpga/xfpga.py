"""Cross-FPGA driver (amendment 15, part C): Vivado on an Artix-7 200T.

Runs on the bench host. It stages each design's sources (copied, never
edited), pushes them to the Vivado host with rsync, starts runner.py there
in the background, and pulls the results back. Nothing CPU-heavy runs on
the bench host.

    python3 -B xfpga.py init                      # register the built-in designs
    python3 -B xfpga.py add-core NAME --group G --rtl-dir DIR [--git-tag T]
    python3 -B xfpga.py add NAME --group G [--top T] [--include DIR] [--lib L=FILE] SRC...
    python3 -B xfpga.py list
    python3 -B xfpga.py run [--pass1-only] [--jobs 6] [--force] NAME...|--all
    python3 -B xfpga.py status
    python3 -B xfpga.py collect                   # pull + results/*.json + summary.csv

`run` = stage + push + start. Registry: designs.json next to this file.
Staging: $XFPGA_STAGE (default ~/xfpga-stage). Raw reports pulled back to
$XFPGA_RAW (default ~/xfpga-raw). Remote: $XFPGA_HOST (default omarchy),
directory ~/hwe-xfpga there.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
REGISTRY = HERE / "designs.json"
RESULTS = HERE / "results"
STAGE = Path(os.environ.get("XFPGA_STAGE", Path.home() / "xfpga-stage"))
RAW = Path(os.environ.get("XFPGA_RAW", Path.home() / "xfpga-raw"))
HOST = os.environ.get("XFPGA_HOST", "omarchy")
RDIR = "hwe-xfpga"                     # relative to the remote home
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20"]

STALL_GEN = "fpga/bench_stall_gen.sv"
BENCH_SI = "fpga/core_bench_si.sv"
V0_TAG = "hwe-bench-v2.8.3"

SYSTEMS = ["claude-opus-5_5_xhigh-v2", "claude-sonnet-5-5_xhigh-v2", "gpt-6_1-sol_xhigh-v2",
           "gpt-6-astra_xhigh-v2", "gpt-6-luna_xhigh-v2", "gpt-5_5_xhigh-v2"]
PILOT = "gpt-6-sol_xhigh-v2"


def lang_of(path: str) -> str:
    """Verilog and SystemVerilog files are read as SystemVerilog, as the Gowin
    flow reads them (its projects set -verilog_std sysv2017 for every file).
    In Verilog-2001 mode Vivado rejects the Ibex sv2v output that Gowin built
    (a reg declared with a non-constant initializer, Synth 8-35)."""
    ext = Path(path).suffix.lower()
    if ext in (".sv", ".v", ".vh", ".svh"):
        return "sv"
    if ext in (".vhd", ".vhdl"):
        return "vhdl"
    raise SystemExit(f"unknown source type: {path}")


# ---------------------------------------------------------------- registry

def load_registry() -> dict:
    return json.loads(REGISTRY.read_text()) if REGISTRY.exists() else {}


def save_registry(reg: dict) -> None:
    REGISTRY.write_text(json.dumps(reg, indent=1) + "\n")


def register(reg: dict, entry: dict, replace: bool = False) -> None:
    n = entry["name"]
    if n in reg and reg[n] != entry and not replace:
        raise SystemExit(f"{n} already registered with a different definition (use --replace)")
    reg[n] = entry


def builtin_designs() -> list[dict]:
    out = []
    for s in SYSTEMS:
        for r in range(1, 7):
            out.append({"name": f"{s}_rep{r}", "group": "agent", "system": s, "rep": r,
                        "kind": "core_si", "rtl_dir": f"bench/v2/{s}/rep{r}/final-rtl"})
    out.append({"name": f"{PILOT}_rep1", "group": "pilot", "system": PILOT, "rep": 1,
                "kind": "core_si", "rtl_dir": f"bench/v2/{PILOT}/rep1/final-rtl"})
    out.append({"name": "v0", "group": "v0", "kind": "core_si", "git_tag": V0_TAG,
                "rtl_dir": "cores/bench/rtl"})
    out.extend(reference_designs())
    return out


def reference_designs() -> list[dict]:
    """The ten reference configurations, with the exact source lists, include
    paths and libraries of their stage-1 Gowin builds (research/v2/
    reference_cores/run_ref.py and reference_vexriscv/run_gowin.py; the
    generated build.tcl files under ~/refcores/gen/<core>/gowin_p0)."""
    rc = Path.home() / "refcores"
    benches = "research/v2/reference_cores/benches"

    def files(paths, lib=None, lib_match=None):
        return [{"path": str(p), "lang": lang_of(str(p)),
                 "lib": lib if (lib and (lib_match is None or lib_match in str(p))) else None}
                for p in paths]

    def glob(d: Path, pat: str, skip=()):
        return [p for p in sorted(d.glob(pat)) if p.name not in skip]

    def ref(key, srcs, bench, include=(), extra=None):
        e = {"name": key, "group": "reference", "kind": "files", "top": "core_bench",
             "files": srcs + files([STALL_GEN]) + files([bench]),
             "include_dirs": [str(i) for i in include]}
        if extra:
            e.update(extra)
        return e

    hz = rc / "Hazard3/hdl"
    hz_srcs = [hz / l.split()[1] for l in (hz / "hazard3.f").read_text().splitlines()
               if l.startswith("file ")]
    neo = rc / "neorv32/rtl/core"
    neo_units = ("package", "sys", "prim", "cpu_decompressor", "cpu_frontend", "cpu_control",
                 "cpu_hwtrig", "cpu_counters", "cpu_regfile", "cpu_alu_shifter",
                 "cpu_alu_muldiv", "cpu_alu_bitmanip", "cpu_alu_fpu", "cpu_alu_cond",
                 "cpu_alu_crypto", "cpu_alu_cfu", "cpu_alu", "cpu_lsu", "cpu_pmp", "cpu_trace",
                 "cpu")
    return [
        ref("vexriscv_maxperf", files([Path.home() / "vexref/VexRiscv/VexRiscv.v"]),
            "research/v2/reference_vexriscv/vex_bench.sv"),
        ref("vexriscv_nocache", files([rc / "vexriscv_nocache/VexRiscv.v"]),
            f"{benches}/vexriscv_nocache_bench.sv"),
        ref("vexiiriscv", files([rc / "vexiiriscv_benchmap/VexiiRiscv.v"]),
            f"{benches}/vexiiriscv_bench.sv"),
        ref("hazard3", files(hz_srcs), f"{benches}/hazard3_bench.sv", include=[hz]),
        # sv2v output (ibex_sv2v.sh): the pinned Ibex plus its bench in one file,
        # which defines core_bench itself; the stall generator is added as in Gowin.
        {"name": "ibex_maxperf", "group": "reference", "kind": "files", "top": "core_bench",
         "files": files([STALL_GEN, rc / "gen/ibex_maxperf_bench.v"]), "include_dirs": []},
        {"name": "ibex_small", "group": "reference", "kind": "files", "top": "core_bench",
         "files": files([STALL_GEN, rc / "gen/ibex_small_bench.v"]), "include_dirs": []},
        ref("ueriscv", files(glob(rc / "riscv/core/riscv", "*.v",
                                  ("riscv_defs.v", "riscv_trace_sim.v", "riscv_xilinx_2r1w.v"))),
            f"{benches}/ueriscv_bench.sv", include=[rc / "riscv/core/riscv"]),
        ref("neorv32", files([neo / f"neorv32_{u}.vhd" for u in neo_units], lib="neorv32")
            + files([f"{benches}/neorv32_cpu_flat.vhd"]),
            f"{benches}/neorv32_bench.sv"),
        ref("biriscv", files(glob(rc / "biriscv/src/core", "*.v",
                                  ("biriscv_defs.v", "biriscv_trace_sim.v",
                                   "biriscv_xilinx_2r1w.v"))),
            f"{benches}/biriscv_bench.sv", include=[rc / "biriscv/src/core"]),
        ref("picorv32", files([rc / "picorv32/picorv32.v"]), f"{benches}/picorv32_bench.sv"),
    ]


# ---------------------------------------------------------------- staging

def abspath(p: str) -> Path:
    q = Path(p).expanduser()
    return q if q.is_absolute() else REPO / q


def git_export(tag: str, sub: str) -> Path:
    dest = STAGE / "git" / tag
    if not (dest / sub).exists():
        dest.mkdir(parents=True, exist_ok=True)
        arch = subprocess.run(["git", "-C", str(REPO), "archive", tag, sub],
                              check=True, capture_output=True).stdout
        subprocess.run(["tar", "-x", "-C", str(dest)], input=arch, check=True)
    return dest / sub


def rtl_sources(rtl: Path) -> list[Path]:
    """Same order as tools/eval/gowin.py rtl_sources: core_pkg.sv first, then
    the other *.sv files sorted by name."""
    srcs = sorted(rtl.glob("*.sv"))
    pkg = rtl / "core_pkg.sv"
    return ([pkg] if pkg in srcs else []) + [p for p in srcs if p != pkg]


def expand(entry: dict) -> dict:
    """Registry entry -> {top, files: [{path(abs), lang, lib}], include_dirs(abs)}."""
    if entry["kind"] == "core_si":
        rtl = git_export(entry["git_tag"], entry["rtl_dir"]) if entry.get("git_tag") \
            else abspath(entry["rtl_dir"])
        srcs = rtl_sources(rtl)
        if not srcs:
            raise SystemExit(f"{entry['name']}: no *.sv in {rtl}")
        files = [{"path": str(p), "lang": "sv", "lib": None} for p in srcs]
        files += [{"path": str(REPO / STALL_GEN), "lang": "sv", "lib": None},
                  {"path": str(REPO / BENCH_SI), "lang": "sv", "lib": None}]
        return {"top": "core_bench", "files": files, "include_dirs": [str(rtl)]}
    if entry["kind"] == "files":
        return {"top": entry.get("top", "core_bench"),
                "files": [{**f, "path": str(abspath(f["path"]))} for f in entry["files"]],
                "include_dirs": [str(abspath(i)) for i in entry.get("include_dirs", [])]}
    raise SystemExit(f"unknown kind {entry['kind']}")


def mirror(p: str) -> str:
    return "root/" + str(Path(p)).lstrip("/")


def stage(entry: dict) -> dict:
    x = expand(entry)
    d = STAGE / "designs" / entry["name"]
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    h = hashlib.sha256()
    files = []
    for f in x["files"]:
        src = Path(f["path"])
        if not src.is_file():
            raise SystemExit(f"{entry['name']}: missing source {src}")
        rel = mirror(f["path"])
        (d / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, d / rel)
        data = src.read_bytes()
        h.update(f"{f['lang']}:{f.get('lib') or ''}:{src.name}:".encode())
        h.update(hashlib.sha256(data).digest())
        files.append({"path": rel, "lang": f["lang"], "lib": f.get("lib"),
                      "origin": f["path"], "sha256": hashlib.sha256(data).hexdigest()})
    incs = []
    for inc in x["include_dirs"]:
        for p in sorted(Path(inc).iterdir()):
            if p.is_file():
                t = d / mirror(str(p))
                t.parent.mkdir(parents=True, exist_ok=True)
                if not t.exists():
                    shutil.copy2(p, t)
        (d / mirror(inc)).mkdir(parents=True, exist_ok=True)
        incs.append(mirror(inc))
    man = {"name": entry["name"], "group": entry.get("group"), "system": entry.get("system"),
           "rep": entry.get("rep"), "top": x["top"], "files": files, "include_dirs": incs,
           "source_sha256": h.hexdigest(), "registry_entry": entry,
           "staged_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    (d / "manifest.json").write_text(json.dumps(man, indent=1))
    return man


# ---------------------------------------------------------------- remote

def sh(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, **kw)


def remote(cmd: str, capture: bool = True) -> str:
    r = subprocess.run(SSH + [HOST, cmd], capture_output=capture, text=True)
    if r.returncode != 0:
        raise SystemExit(f"remote command failed ({r.returncode}): {cmd}\n{r.stderr}")
    return r.stdout if capture else ""


def push(names: list[str]) -> None:
    remote(f"mkdir -p {RDIR}/designs {RDIR}/runs {RDIR}/logs")
    sh(["rsync", "-a", "-e", " ".join(SSH), str(HERE / "runner.py"), str(HERE / "flow.tcl"),
        f"{HOST}:{RDIR}/"])
    for n in names:
        sh(["rsync", "-a", "--delete", "-e", " ".join(SSH), f"{STAGE}/designs/{n}/",
            f"{HOST}:{RDIR}/designs/{n}/"])


def runner_alive() -> str:
    out = remote(f"cd {RDIR} && if [ -f runner.pid ] && kill -0 $(cat runner.pid) 2>/dev/null; "
                 f"then cat runner.pid; fi")
    return out.strip()


def start(names: list[str], pass1_only: bool, jobs: int, force: bool) -> None:
    pid = runner_alive()
    if pid:
        raise SystemExit(f"a runner is already active on {HOST} (pid {pid}); wait or use status")
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    flags = (" --pass1-only" if pass1_only else "") + (" --force" if force else "")
    # The cd is a separate statement so the backgrounded command is the runner
    # alone (a backgrounded `cd && ...` list keeps the ssh channel open).
    cmd = (f"cd {RDIR} || exit 1; setsid nohup nice -n 10 python3 -u runner.py --jobs {jobs}"
           f"{flags} {' '.join(names)} > logs/runner-{ts}.log 2>&1 < /dev/null & echo started")
    print(remote(cmd).strip(), f"log: {RDIR}/logs/runner-{ts}.log")


def status() -> None:
    pid = runner_alive()
    print(f"runner: {'running pid ' + pid if pid else 'not running'}")
    print(remote(f"cd {RDIR} && ls -t logs/runner-*.log 2>/dev/null | head -1 | xargs -r tail -n 15;"
                 f" echo; echo vivado jobs: $(ps -u $(id -u) -o args | grep -c '^/opt/Xilinx/.*/unwrapped/lnx64.o/vivado');"
                 f" cat /proc/loadavg; df -h ~ | tail -1; free -g | sed -n 2p"))


def pull() -> None:
    RAW.mkdir(parents=True, exist_ok=True)
    sh(["rsync", "-a", "--delete", "-e", " ".join(SSH),
        "--include=*/", "--include=design.json", "--include=result.tsv", "--include=*.rpt",
        "--include=vivado.log", "--include=clock.xdc", "--include=job.tcl", "--exclude=*",
        f"{HOST}:{RDIR}/runs/", f"{RAW}/runs/"])
    sh(["rsync", "-a", "-e", " ".join(SSH), f"{HOST}:{RDIR}/logs/", f"{RAW}/logs/"])


# ---------------------------------------------------------------- results

def gowin_reference(entry: dict) -> dict | None:
    """The design's own Gowin numbers, for the side-by-side only."""
    try:
        if entry["group"] in ("agent", "pilot"):
            d = REPO / "bench/v2" / entry["system"] / f"rep{entry['rep']}"
            final = json.loads((d / "summary.json").read_text())["final_fitness"]
            rows = [json.loads(l) for l in (d / "log.jsonl").read_text().splitlines() if l.strip()]
            acc = [r for r in rows if r.get("outcome") == "improvement" and r.get("fitness") == final]
            if acc:
                r = acc[-1]
                return {"fmax_mhz": r["fmax_mhz"], "lut4": r["lut4"], "ff": r["ff"],
                        "source": f"bench/v2/{entry['system']}/rep{entry['rep']}/log.jsonl {r['id']}"}
        if entry["group"] == "reference":
            p = (REPO / "research/v2/reference_vexriscv/result.json"
                 if entry["name"] == "vexriscv_maxperf"
                 else REPO / f"research/v2/reference_cores/results/{entry['name']}.json")
            s = json.loads(p.read_text())["summary"]
            return {"fmax_mhz": s.get("fmax_mhz"), "lut4": s.get("lut4"), "ff": s.get("ff"),
                    "source": str(p.relative_to(REPO))}
    except (OSError, KeyError, ValueError):
        return None
    return None


def worst_path_pins(rpt: Path) -> list[str]:
    """Pins along the first (worst) path of worst_paths.rpt, in order."""
    if not rpt.exists():
        return []
    text = rpt.read_text(errors="replace")
    parts = text.split("\nSlack")
    if len(parts) < 2:
        return []
    first = parts[1]
    return [l.split()[-1] for l in first.splitlines()
            if "net (" in l and len(l.split()) >= 4]


def path_info(name: str, build: str) -> dict:
    pins = worst_path_pins(RAW / "runs" / name / build / "worst_paths.rpt")
    if not pins:
        return {}
    # The bench's dmem is the only memory named dmem_reg* (distributed RAM
    # in core_bench_si.sv, block RAM in the reference benches).
    via = any(pn.split("/")[0].startswith("dmem_reg") for pn in pins)
    insts = []
    for pn in pins:
        parts = pn.split("/")
        inst = "/".join(parts[:2]) if parts[0] == "cpu" and len(parts) > 2 else parts[0]
        if not insts or insts[-1] != inst:
            insts.append(inst)
    return {"via_dmem": via, "instances": insts}


def luts_excl_top(rec: dict) -> int | None:
    """Slice LUTs minus the cells that sit directly in core_bench (the agents'
    distributed-RAM dmem, 1025 LUTs; 1 to 4 LUTs in the reference benches).
    Robust to Vivado's hierarchy rebuild, which can file core logic under the
    stall generator's instance, so core_luts (the core instance alone) is only
    a lower bound."""
    top = next((r for r in rec.get("area_hier", []) if r.get("instance") == "(core_bench)"), None)
    tot = (rec.get("area") or {}).get("slice_luts")
    if top is None or tot is None or not isinstance(top.get("Total LUTs"), int):
        return None
    return tot - top["Total LUTs"]


def core_instance(hier: list[dict]) -> dict | None:
    kids = [r for r in hier if r.get("depth") == 1 and isinstance(r.get("Total LUTs"), int)
            and not r["instance"].startswith("(")]
    return max(kids, key=lambda r: r["Total LUTs"]) if kids else None


CSV_COLS = ["design", "group", "system", "rep", "status", "F1", "P2", "fmax_default",
            "fmax_explore", "fmax_extratimingopt", "fmax_median", "slice_luts",
            "slice_registers", "lut_as_memory", "block_ram_tile", "dsps", "core_instance",
            "core_luts", "core_ffs", "luts_excl_bench_top", "p2_default_wns", "p2_default_logic_levels", "p2_default_via_dmem",
            "gowin_fmax", "gowin_lut4", "wall_sec", "error"]


def collect(do_pull: bool = True) -> None:
    if do_pull:
        pull()
    reg = load_registry()
    RESULTS.mkdir(exist_ok=True)
    rows = []
    for name, entry in reg.items():
        dj = RAW / "runs" / name / "design.json"
        if not dj.exists():
            continue
        rec = json.loads(dj.read_text())
        man_p = STAGE / "designs" / name / "manifest.json"
        man = json.loads(man_p.read_text()) if man_p.exists() else {}
        if man and man.get("source_sha256") != rec.get("source_sha256"):
            print(f"warning: {name}: staged sources differ from the run's (stale result)")
        core = core_instance(rec.get("area_hier", []))
        for pk, builds in (("pass1", {"Default": rec.get("pass1")}), ("pass2", rec.get("pass2") or {})):
            for dv, b in builds.items():
                if b:
                    b["worst_path"] = path_info(name, f"{'p1' if pk == 'pass1' else 'p2'}_{dv}")
        out = {"design": name, "group": entry.get("group"), "system": entry.get("system"),
               "rep": entry.get("rep"), "registry_entry": entry,
               "sources": [{"origin": f["origin"], "lang": f["lang"], "lib": f["lib"],
                            "sha256": f["sha256"]} for f in man.get("files", [])],
               "include_dirs": man.get("include_dirs"),
               "flow": {"tool": rec.get("vivado_version"), "part": rec.get("part"),
                        "spec": "research/runs/EXP-2026-09-28-v2-main/amendment_15.yaml "
                                "part_c_cross_fpga"},
               **{k: v for k, v in rec.items() if k not in ("design", "group", "system", "rep")},
               "core_area": core,
               "gowin_reference": gowin_reference(entry)}
        (RESULTS / f"{name}.json").write_text(json.dumps(out, indent=1) + "\n")
        p2 = rec.get("fmax_p2", {})
        area = rec.get("area", {})
        pd = rec.get("pass2", {}).get("Default", {})
        gw = out["gowin_reference"] or {}
        err = rec.get("error_lines") or ([rec["error"]] if rec.get("error") else [])
        rows.append({"design": name, "group": entry.get("group"), "system": entry.get("system"),
                     "rep": entry.get("rep"), "status": rec.get("status"),
                     "F1": rec.get("F1"), "P2": rec.get("P2"),
                     "fmax_default": p2.get("Default"), "fmax_explore": p2.get("Explore"),
                     "fmax_extratimingopt": p2.get("ExtraTimingOpt"),
                     "fmax_median": rec.get("fmax_mhz"),
                     "slice_luts": area.get("slice_luts"),
                     "slice_registers": area.get("slice_registers"),
                     "lut_as_memory": area.get("lut_as_memory"),
                     "block_ram_tile": area.get("block_ram_tile"), "dsps": area.get("dsps"),
                     "core_instance": core and core["instance"],
                     "core_luts": core and core.get("Total LUTs"),
                     "core_ffs": core and core.get("FFs"),
                     "luts_excl_bench_top": luts_excl_top(rec),
                     "p2_default_wns": pd.get("wns"),
                     "p2_default_logic_levels": pd.get("logic_levels"),
                     "p2_default_via_dmem": (pd.get("worst_path") or {}).get("via_dmem"),
                     "gowin_fmax": gw.get("fmax_mhz"), "gowin_lut4": gw.get("lut4"),
                     "wall_sec": rec.get("wall_sec"),
                     "error": " | ".join(err)[:500] if err else ""})
    order = {"agent": 0, "pilot": 1, "v0": 2, "baseline": 3, "ablation": 4, "reference": 5}
    rows.sort(key=lambda r: (order.get(r["group"], 9), r["design"]))
    with open(RESULTS / "summary.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_COLS)
        w.writeheader()
        w.writerows(rows)
    print(f"{len(rows)} designs -> {RESULTS}/summary.csv")


# ---------------------------------------------------------------- CLI

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init")
    a = sub.add_parser("add-core", help="a core with the nret 1 bench wrapper (agents, V0, baseline)")
    a.add_argument("name")
    a.add_argument("--group", required=True)
    a.add_argument("--rtl-dir", required=True, help="dir with the core's *.sv (repo-relative ok)")
    a.add_argument("--git-tag", help="read --rtl-dir from this git tag instead of the worktree")
    a.add_argument("--system")
    a.add_argument("--rep", type=int)
    a.add_argument("--replace", action="store_true")
    b = sub.add_parser("add", help="any design given as an ordered source list")
    b.add_argument("name")
    b.add_argument("--group", required=True)
    b.add_argument("--top", default="core_bench")
    b.add_argument("--include", action="append", default=[])
    b.add_argument("--lib", action="append", default=[], help="LIB=FILE: VHDL library of FILE")
    b.add_argument("--replace", action="store_true")
    b.add_argument("sources", nargs="+")
    sub.add_parser("list")
    r = sub.add_parser("run")
    r.add_argument("--pass1-only", action="store_true")
    r.add_argument("--jobs", type=int, default=6)
    r.add_argument("--force", action="store_true")
    r.add_argument("--all", action="store_true")
    r.add_argument("names", nargs="*")
    sub.add_parser("status")
    c = sub.add_parser("collect")
    c.add_argument("--no-pull", action="store_true")
    a = ap.parse_args()

    reg = load_registry()
    if a.cmd == "init":
        for e in builtin_designs():
            register(reg, e)
        save_registry(reg)
        print(f"{len(reg)} designs registered")
    elif a.cmd == "add-core":
        e = {"name": a.name, "group": a.group, "kind": "core_si", "rtl_dir": a.rtl_dir}
        if a.git_tag:
            e["git_tag"] = a.git_tag
        if a.system:
            e["system"] = a.system
        if a.rep is not None:
            e["rep"] = a.rep
        expand(e)
        register(reg, e, a.replace)
        save_registry(reg)
    elif a.cmd == "add":
        libs = dict(reversed(x.split("=", 1)) for x in a.lib)
        e = {"name": a.name, "group": a.group, "kind": "files", "top": a.top,
             "files": [{"path": s, "lang": lang_of(s), "lib": libs.get(s)} for s in a.sources],
             "include_dirs": a.include}
        expand(e)
        register(reg, e, a.replace)
        save_registry(reg)
    elif a.cmd == "list":
        for n, e in reg.items():
            print(f"{n:40s} {e['group']:10s} {e['kind']}")
    elif a.cmd == "run":
        names = list(reg) if a.all else a.names
        missing = [n for n in names if n not in reg]
        if missing or not names:
            raise SystemExit(f"unknown or no designs: {missing}")
        for n in names:
            m = stage(reg[n])
            print(f"staged {n}: {len(m['files'])} files, sha256 {m['source_sha256'][:12]}")
        push(names)
        start(names, a.pass1_only, a.jobs, a.force)
    elif a.cmd == "status":
        status()
    elif a.cmd == "collect":
        collect(not a.no_pull)


if __name__ == "__main__":
    main()
