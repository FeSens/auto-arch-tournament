"""FPGA fitness on the vendor flow: report parsing, fail-loud area, the
median over placement options, and the nextpnr helpers the research
scripts still use."""
import asyncio

import pytest

from tools.eval import fpga, gowin

_TR = """1. Timing Messages
2.3 Max Frequency Summary
2.4 Total Negative Slack Summary
...
2.3 Max Frequency Summary
  NO.   Clock Name    Constraint    Actual Fmax   Level   Entity
 ===== ============ ============== ============= ======= ========
  1     clock        200.000(MHz)   5.140(MHz)    150     TOP
"""
_RPT = """  Logic                       | 12312/20736                         |  60%
    --SSRAM(RAM16)            | 8                                   | -
  Register                    | 460/15750                           |  3%
  BSRAM                       | 6/46                                | 14%
  DSP                         | 6/24                                | 25%
"""


def _write(outdir, tr=_TR, rpt=_RPT):
    d = outdir / "impl" / "pnr"
    d.mkdir(parents=True)
    if tr is not None:
        (d / "core_bench.tr").write_text(tr)
    if rpt is not None:
        (d / "core_bench.rpt.txt").write_text(rpt)


def test_parse_reads_actual_fmax_not_the_constraint(tmp_path):
    _write(tmp_path)
    r = gowin.parse_reports(tmp_path)
    assert r["fmax_mhz"] == 5.140 and r["levels"] == 150
    assert (r["logic"], r["regs"], r["lutram"], r["bsram"], r["dsp"]) == (12312, 460, 8, 6, 6)


def test_missing_reports_are_a_failed_placement(tmp_path):
    _write(tmp_path, tr=None)
    assert gowin.parse_reports(tmp_path)["placement_failed"] is True


def _fake(fmax_by_option, logic=12312):
    def build_all(worktree, rtl_dir, bench_sv, gen_dir, env=None, options=gowin.PLACE_OPTIONS):
        return [{"place_option": p, "placement_failed": fmax_by_option[p] is None,
                 "fmax_mhz": fmax_by_option[p], "levels": 10, "logic": logic, "regs": 460,
                 "lutram": 0, "bsram": 4, "dsp": 1, "reason": "does not fit"}
                for p in options]
    return build_all


def _patch(monkeypatch, fmax_by_option, logic=12312):
    monkeypatch.setattr(gowin, "build_all", _fake(fmax_by_option, logic))
    monkeypatch.setattr(fpga, "run_coremark_ipc", lambda *a, **k: {
        'completed': True, 'iter_per_cycle': 3e-6, 'cycles': 1, 'iterations': 10})


def test_score_is_median_over_placement_options(monkeypatch, tmp_path):
    _patch(monkeypatch, {0: 48.918, 1: 49.916, 2: 49.5})
    r = fpga.run_fpga_eval(str(tmp_path))
    assert r['fmax_mhz'] == 49.5 and r['lut4'] == 12312 and r['ff'] == 460
    assert r['fitness'] == pytest.approx(49.5 * 3e-6 * 1e6)


def test_any_option_failing_fails_the_design(monkeypatch, tmp_path):
    _patch(monkeypatch, {0: 48.9, 1: None, 2: 49.9})
    r = fpga.run_fpga_eval(str(tmp_path))
    assert r['placement_failed'] is True and 'fitness' not in r


def test_unparsed_area_fails_instead_of_scoring_zero(monkeypatch, tmp_path):
    _patch(monkeypatch, {0: 48.9, 1: 49.9, 2: 49.9}, logic=None)
    r = fpga.run_fpga_eval(str(tmp_path))
    assert r['bench_failed'] is True and r['reason'].startswith('fpga_report_unparsed')
    assert 'fitness' not in r


def test_bench_wrapper_follows_nret(tmp_path):
    (tmp_path / "cores" / "x").mkdir(parents=True)
    (tmp_path / "cores" / "x" / "core.yaml").write_text("nret: 1\n")
    assert fpga._bench_sv(str(tmp_path), "x") == "fpga/core_bench_si.sv"
    (tmp_path / "cores" / "x" / "core.yaml").write_text("nret: 2\n")
    assert fpga._bench_sv(str(tmp_path), "x") == "fpga/core_bench.sv"


def test_project_lists_core_pkg_first_and_the_contract_files(tmp_path):
    rtl = tmp_path / "rtl"
    rtl.mkdir()
    for n in ("alu.sv", "core.sv", "core_pkg.sv"):
        (rtl / n).write_text("")
    tcl = gowin.project_tcl(tmp_path, rtl, "fpga/core_bench_si.sv", 1)
    files = [l.split()[1] for l in tcl.splitlines() if l.startswith("add_file")]
    assert files[0].endswith("core_pkg.sv")
    assert [f.split("/")[-1] for f in files[3:]] == [
        "bench_stall_gen.sv", "core_bench_si.sv", "Tang_Nano_20K.cst", "clock.sdc"]
    assert "set_option -place_option 1" in tcl and gowin.PART in tcl


def test_build_timeout_counts_as_failed(monkeypatch, tmp_path):
    fake = tmp_path / "gw" / "IDE" / "bin"
    fake.mkdir(parents=True)
    (fake / "gw_sh").write_text("#!/usr/bin/env bash\nsleep 600\n")
    (fake / "gw_sh").chmod(0o755)
    monkeypatch.setattr(gowin, "GOWIN_HOME", tmp_path / "gw")
    monkeypatch.setattr(gowin, "BUILD_TIMEOUT_SEC", 1)
    rtl = tmp_path / "rtl"
    rtl.mkdir()
    r = gowin.build(tmp_path, rtl, "fpga/core_bench_si.sv", 0, tmp_path / "out")
    assert r['placement_failed'] is True and r.get('timed_out') is True


def test_pad_module_matches_calibration_driver():
    import importlib.util
    from pathlib import Path
    spec = importlib.util.spec_from_file_location(
        "calibrate", Path(__file__).parents[2] / "research/v2/scripts/calibrate.py")
    cal = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cal)
    for k in (0, 5, 33):
        assert fpga.pad_module(k) == cal.pad_module(k)
