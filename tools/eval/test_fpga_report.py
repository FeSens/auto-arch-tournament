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
