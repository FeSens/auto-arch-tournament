"""Gowin Fmax of VexRiscv in the V2 harness flow, using the harness's own
project_tcl/_run_gw_sh/parse_reports/summarize (read-only import; run with
python3 -B so nothing is written into the repo). No eval slot is taken: this
runs at nice 19 beside the scored campaign."""
import json, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path("/home/bench/auto-arch-tournament")
sys.path.insert(0, str(REPO))
from tools.eval import gowin  # noqa: E402

HERE = Path(__file__).resolve().parent
VEX = HERE / "VexRiscv" / "VexRiscv.v"
BENCH = HERE / "vex_bench.sv"
EMPTY = HERE / "empty_rtl"
EMPTY.mkdir(exist_ok=True)


def one(p: int) -> dict:
    out = HERE / "gen" / f"gowin_p{p}"
    if out.exists():
        import shutil
        shutil.rmtree(out)
    out.mkdir(parents=True)
    tcl = gowin.project_tcl(REPO, EMPTY, str(BENCH), p)
    tcl = tcl.replace("add_file ", f"add_file {VEX}\nadd_file ", 1)
    (out / "build.tcl").write_text(tcl)
    timed_out = gowin._run_gw_sh(out, out / "gw.log", gowin.gowin_env(None, out))
    res = {"placement_failed": True, "fmax_mhz": None, "timed_out": True} if timed_out \
        else gowin.parse_reports(out)
    return {"place_option": p, **res}


with ThreadPoolExecutor(max_workers=3) as ex:
    results = list(ex.map(one, gowin.PLACE_OPTIONS))
summary = gowin.summarize(results)
(HERE / "result.json").write_text(json.dumps({"results": results, "summary": summary}, indent=1))
print(json.dumps(summary, indent=1))
