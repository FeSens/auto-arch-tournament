"""run_fpga_eval must fail, not score, when nextpnr's utilisation report
can't be parsed. A defaulted LUT4 of 0 would win every area comparison."""
import asyncio

from tools.eval import fpga

_LOG_OK = "Info: LUT4:  9563/20736  46%\nInfo: DFF:  2911/15552  18%\n"


def _patch(monkeypatch, log: str):
    async def seeds(worktree, generated_dir="generated", env=None):
        return [{'seed': s, 'fmax_mhz': 80.0 + s, 'log': log, 'returncode': 0,
                 'placement_failed': False} for s in fpga.SEEDS]
    monkeypatch.setattr(fpga, "_run_all_seeds", seeds)
    monkeypatch.setattr(fpga, "run_coremark_ipc", lambda *a, **k: {
        'completed': True, 'iter_per_cycle': 3e-6, 'cycles': 1, 'iterations': 10})


def test_parsed_report_scores(monkeypatch, tmp_path):
    _patch(monkeypatch, _LOG_OK)
    r = fpga.run_fpga_eval(str(tmp_path))
    assert r['lut4'] == 9563 and r['ff'] == 2911
    assert r['fitness'] > 0


def test_missing_lut4_fails_instead_of_scoring_zero(monkeypatch, tmp_path):
    _patch(monkeypatch, "Info: DFF:  2911/15552  18%\n")
    r = fpga.run_fpga_eval(str(tmp_path))
    assert r['bench_failed'] is True
    assert r['reason'].startswith('fpga_report_unparsed')
    assert 'LUT4' in r['reason']
    assert 'fitness' not in r and 'lut4' not in r


def test_missing_dff_fails(monkeypatch, tmp_path):
    _patch(monkeypatch, "Info: LUT4:  9563/20736  46%\n")
    r = fpga.run_fpga_eval(str(tmp_path))
    assert r['bench_failed'] is True
    assert 'DFF' in r['reason']


def test_memory_and_dsp_cells_reported(monkeypatch, tmp_path):
    log = (_LOG_OK + "Info: RAM16SDP4:  36/648  5%\nInfo: BSRAM:  4/46  8%\n"
           "Info: MULT36X36:  1/12  8%\nInfo: MULT18X18:  0/48  0%\n")
    _patch(monkeypatch, log)
    r = fpga.run_fpga_eval(str(tmp_path))
    assert (r['lutram'], r['bsram'], r['dsp']) == (36, 4, 1)


def test_nextpnr_timeout_counts_as_failed_seed(monkeypatch, tmp_path):
    # A stand-in nextpnr script that never finishes must be killed at the
    # cap and reported as a failed seed, not hang the evaluation.
    script = tmp_path / "hang.sh"
    script.write_text("#!/usr/bin/env bash\nsleep 600\n")
    monkeypatch.setattr(fpga, "NEXTPNR_SCRIPT", str(script))
    monkeypatch.setattr(fpga, "NEXTPNR_TIMEOUT_SEC", 1)
    r = asyncio.run(fpga.run_seed(1, str(tmp_path), str(tmp_path / "out")))
    assert r['placement_failed'] is True and r.get('timed_out') is True
    assert r['fmax_mhz'] is None
