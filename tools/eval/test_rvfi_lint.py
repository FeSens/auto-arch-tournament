from pathlib import Path

from tools.eval.rvfi_lint import check_ch0_contract


def _write(rtl_dir: Path, name: str, body: str) -> None:
    rtl_dir.mkdir(parents=True, exist_ok=True)
    (rtl_dir / name).write_text(body)


def test_ch0_tied_apostrophe_zero(tmp_path):
    _write(tmp_path, "core.sv", "module core;\n  assign io_rvfi_valid_0 = '0;\nendmodule\n")
    out = check_ch0_contract(tmp_path)
    assert out['passed'] is False
    assert "io_rvfi_valid_0" in out['detail']
    assert "core.sv:2" in out['detail']


def test_ch0_tied_1b0(tmp_path):
    _write(tmp_path, "core.sv", "module core;\nassign io_rvfi_valid_0 = 1'b0;\nendmodule\n")
    out = check_ch0_contract(tmp_path)
    assert out['passed'] is False
    assert "core.sv:2" in out['detail']


def test_ch0_tied_bare_zero(tmp_path):
    _write(tmp_path, "core.sv", "assign io_rvfi_valid_0 = 0;\n")
    out = check_ch0_contract(tmp_path)
    assert out['passed'] is False


def test_ch1_tied_is_fine(tmp_path):
    # Single-issue tie of channel 1 is the legitimate pattern.
    _write(tmp_path, "core.sv", "assign io_rvfi_valid_1 = '0;\n")
    assert check_ch0_contract(tmp_path) == {'passed': True}


def test_ch0_driven_dynamically_passes(tmp_path):
    # Real wiring: ch0 driven from a pipeline signal. Must pass.
    _write(tmp_path, "core.sv",
           "assign io_rvfi_valid_0 = mem_wb_w.valid;\n"
           "assign io_rvfi_valid_1 = '0;\n")
    assert check_ch0_contract(tmp_path) == {'passed': True}


def test_comment_with_pattern_is_ignored(tmp_path):
    _write(tmp_path, "core.sv",
           "// historical: assign io_rvfi_valid_0 = '0;\n"
           "assign io_rvfi_valid_0 = mem_wb_w.valid;\n")
    assert check_ch0_contract(tmp_path) == {'passed': True}


def test_no_sv_files(tmp_path):
    out = check_ch0_contract(tmp_path)
    assert out['passed'] is False
    assert "no .sv files" in out['detail']


def test_missing_dir(tmp_path):
    out = check_ch0_contract(tmp_path / "missing")
    assert out['passed'] is False
    assert "not a directory" in out['detail']


def test_multi_file_finds_violation(tmp_path):
    _write(tmp_path, "good.sv", "assign io_rvfi_valid_0 = mem_wb_w.valid;\n")
    _write(tmp_path, "bad.sv",  "assign io_rvfi_valid_0 = '0;\n")
    out = check_ch0_contract(tmp_path)
    assert out['passed'] is False
    assert "bad.sv" in out['detail']


def test_first_violation_reported(tmp_path):
    # Two distinct violations across files; report the first by sorted name.
    _write(tmp_path, "a.sv", "assign io_rvfi_valid_0 = '0;\n")
    _write(tmp_path, "b.sv", "assign io_rvfi_valid_0 = 1'b0;\n")
    out = check_ch0_contract(tmp_path)
    assert out['passed'] is False
    assert "a.sv" in out['detail']


# Dual-issue safety: the legitimate dual-issue patterns must not be flagged.
# Channel 0 must always carry retirement; tying it to '0 unconditionally is
# wrong in both single- and dual-issue, but conditional zeros and signal
# drives are fine.

def test_dual_issue_both_channels_driven_passes(tmp_path):
    _write(tmp_path, "core.sv",
           "assign io_rvfi_valid_0 = retire_older.valid;\n"
           "assign io_rvfi_valid_1 = retire_younger.valid;\n")
    assert check_ch0_contract(tmp_path) == {'passed': True}


def test_dual_issue_conditional_zero_passes(tmp_path):
    # ch0 = 0 when no instr retires this cycle, real signal otherwise.
    # The lint requires the RHS to be JUST a constant for it to flag —
    # any conditional or expression sails through.
    _write(tmp_path, "core.sv",
           "assign io_rvfi_valid_0 = (n_retired >= 1) ? retire[0].valid : 1'b0;\n"
           "assign io_rvfi_valid_1 = (n_retired >= 2) ? retire[1].valid : 1'b0;\n")
    assert check_ch0_contract(tmp_path) == {'passed': True}


def test_dual_issue_with_ch0_tied_still_flagged(tmp_path):
    # Dual-issue is no excuse — tying ch0 off is broken regardless of width.
    _write(tmp_path, "core.sv",
           "assign io_rvfi_valid_0 = '0;\n"
           "assign io_rvfi_valid_1 = retire_younger.valid;\n")
    out = check_ch0_contract(tmp_path)
    assert out['passed'] is False
