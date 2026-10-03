"""Gowin Fmax and area of an open-source reference core in the V2 harness flow.

Same method as research/v2/reference_vexriscv/run_gowin.py: the harness's own
project_tcl/_run_gw_sh/parse_reports/summarize (read-only import; run with
python3 -B so nothing is written into the repo), GW2AR-LV18QN88C8/I7, 5 ns
target, place options 0/1/2 in parallel, median Fmax. The core sources live
in ~/refcores/<repo> (pinned commits in README.md); each core gets a bench
wrapper in benches/ that mirrors fpga/core_bench_si.sv. No eval slot is
taken: run at nice 19 beside the scored campaign.

    nice -n 19 python3 -B run_ref.py <core> [<core> ...]
"""
import json
import shutil
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path("/home/bench/auto-arch-tournament")
sys.path.insert(0, str(REPO))
from tools.eval import gowin  # noqa: E402

HERE = Path(__file__).resolve().parent
RC = Path.home() / "refcores"
GEN = RC / "gen"
EMPTY = RC / "empty_rtl"


def _glob(d: Path, pat: str, skip=()) -> list[Path]:
    return [p for p in sorted(d.glob(pat)) if p.name not in skip]


UE_SKIP = ("riscv_defs.v", "riscv_trace_sim.v", "riscv_xilinx_2r1w.v")
BI_SKIP = ("biriscv_defs.v", "biriscv_trace_sim.v", "biriscv_xilinx_2r1w.v")

# sources: added before the bench; include: -include_path; opts: extra
# set_option lines.
CORES = {
    "picorv32": {
        "sources": [RC / "picorv32/picorv32.v"],
    },
    "ueriscv": {
        "sources": _glob(RC / "riscv/core/riscv", "*.v", UE_SKIP),
        "include": [RC / "riscv/core/riscv"],
    },
    "biriscv": {
        "sources": _glob(RC / "biriscv/src/core", "*.v", BI_SKIP),
        "include": [RC / "biriscv/src/core"],
    },
    "hazard3": {
        "sources": [RC / "Hazard3/hdl" / l.split()[1] for l in
                    (RC / "Hazard3/hdl/hazard3.f").read_text().splitlines()
                    if l.startswith("file ")],
        "include": [RC / "Hazard3/hdl"],
    },
    # sv2v output of ~/refcores/ibex_sv2v.sh <cfg>: the pinned Ibex plus
    # benches/ibex_<cfg>_bench.src.sv in one Verilog file.
    # neorv32_cpu and its sub-entities in compile order (rtl/file_list_core.f,
    # with the register file and CFU moved ahead of the CPU), library neorv32.
    "neorv32": {
        "sources": [*(RC / "neorv32/rtl/core" / f"neorv32_{n}.vhd" for n in (
            "package", "sys", "prim", "cpu_decompressor", "cpu_frontend", "cpu_control",
            "cpu_hwtrig", "cpu_counters", "cpu_regfile", "cpu_alu_shifter", "cpu_alu_muldiv",
            "cpu_alu_bitmanip", "cpu_alu_fpu", "cpu_alu_cond", "cpu_alu_crypto",
            "cpu_alu_cfu", "cpu_alu", "cpu_lsu", "cpu_pmp", "cpu_trace", "cpu")),
                    HERE / "benches/neorv32_cpu_flat.vhd"],
        "lib": {"neorv32": "neorv32/rtl/core/"},
        "opts": ["set_option -vhdl_std vhd2008"],
    },
    # sbt "runMain vexriscv.demo.GenFullNoMmuNoCache", VexRiscv baf7dc82.
    "vexriscv_nocache": {"sources": [RC / "vexriscv_nocache/VexRiscv.v"]},
    # VexiiRiscv 4e38f271: sbt "Test/runMain vexiiriscv.Generate --xlen=32 --with-rvm
    # --allow-bypass-from=0 --relaxed-branch --relaxed-btb --fetch-fork-at=1 --with-btb
    # --with-gshare --with-ras --regfile-async" (Synt.scala "rv32im branchPredict").
    "vexiiriscv": {"sources": [RC / "vexiiriscv/VexiiRiscv.v"]},
    "ibex_small": {"sources": [], "bench": GEN / "ibex_small_bench.v"},
    "ibex_maxperf": {"sources": [], "bench": GEN / "ibex_maxperf_bench.v"},
}


def one(name: str, cfg: dict, p: int) -> dict:
    out = GEN / name / f"gowin_p{p}"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    bench = cfg.get("bench", HERE / "benches" / f"{name}_bench.sv")
    tcl = gowin.project_tcl(REPO, EMPTY, str(bench), p)
    pre = "".join(f"add_file {s}\n" for s in cfg["sources"])
    tcl = tcl.replace("add_file ", pre + "add_file ", 1)
    opts = [f"set_option -include_path {{{';'.join(map(str, cfg['include']))}}}"] \
        if cfg.get("include") else []
    opts += cfg.get("opts", [])
    for lib, sub in cfg.get("lib", {}).items():
        opts += [f"set_file_prop -lib {lib} {f}" for f in cfg["sources"] if sub in str(f)]
    if opts:
        tcl = tcl.replace("run all", "\n".join(opts) + "\nrun all", 1)
    (out / "build.tcl").write_text(tcl)
    timed_out = gowin._run_gw_sh(out, out / "gw.log", gowin.gowin_env(None, out))
    res = {"placement_failed": True, "fmax_mhz": None, "timed_out": True} if timed_out \
        else gowin.parse_reports(out)
    return {"place_option": p, **res}


def run(name: str) -> dict:
    cfg = CORES[name]
    EMPTY.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=len(gowin.PLACE_OPTIONS)) as ex:
        results = list(ex.map(lambda p: one(name, cfg, p), gowin.PLACE_OPTIONS))
    summary = gowin.summarize(results)
    res_dir = HERE / "results"
    res_dir.mkdir(exist_ok=True)
    (res_dir / f"{name}.json").write_text(
        json.dumps({"core": name, "results": results, "summary": summary}, indent=1))
    return summary


if __name__ == "__main__":
    for n in sys.argv[1:]:
        s = run(n)
        print(n, json.dumps({k: s.get(k) for k in
                             ("placement_failed", "fmax_mhz", "seeds", "lut4", "ff",
                              "bsram", "dsp", "reason")}), flush=True)
