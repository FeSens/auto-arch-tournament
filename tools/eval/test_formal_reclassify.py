"""Tests for the no_checks_generated re-classification heuristic."""
from tools.eval.formal import _reclassify_no_checks_generated


def test_genuinely_no_checks_returns_original_label():
    # genchecks.py crashed; no SBY output at all.
    out = """=== genchecks ===
Traceback (most recent call last):
  File ".../genchecks.py", line 12, in <module>
    raise RuntimeError("config parse error")

Formal: 0 passed, 1 failed
Failed: no_checks_generated
"""
    assert _reclassify_no_checks_generated(out) == "no_checks_generated"


def test_sby_done_pass_proves_make_ran():
    out = """=== make ===
SBY 16:17:14 [insn_xori_ch0] DONE (PASS, rc=0)

Formal: 0 passed, 1 failed
Failed: no_checks_generated
"""
    assert _reclassify_no_checks_generated(out) == "make_failed_during_execution"


def test_sby_done_fail_proves_make_ran():
    out = """SBY 16:13:14 [insn_beq_ch0] DONE (FAIL, rc=0)

Formal: 0 passed, 1 failed
Failed: no_checks_generated
"""
    assert _reclassify_no_checks_generated(out) == "make_failed_during_execution"


def test_sby_done_error_proves_make_ran():
    # The exact pattern observed live: PREUNSAT on _ch1 returning
    # rc=16 with engine returning ERROR (which is itself a separate
    # bug shape but proves SBY did execute).
    out = """SBY 17:10:31 [insn_sltu_ch1] DONE (ERROR, rc=16)

Formal: 0 passed, 1 failed
Failed: no_checks_generated
"""
    assert _reclassify_no_checks_generated(out) == "make_failed_during_execution"


def test_make_status_target_failure_proves_make_ran():
    out = """make[1]: *** [insn_sltiu_ch0/status] Error 1
make[1]: Target `all' not remade because of errors.

Formal: 0 passed, 1 failed
Failed: no_checks_generated
"""
    assert _reclassify_no_checks_generated(out) == "make_failed_during_execution"


def test_engine_status_line_proves_make_ran():
    out = """SBY 17:11:11 [reg_ch0] engine_0: Status returned by engine: pass
SBY 17:11:11 [reg_ch0] summary: engine_0 (smtbmc bitwuzla) returned pass

Formal: 0 passed, 1 failed
Failed: no_checks_generated
"""
    assert _reclassify_no_checks_generated(out) == "make_failed_during_execution"


def test_real_observed_log_excerpt():
    # Actual excerpt from gemini-3_1-pro-rep1 slot 1's orchestrator log,
    # the one that produced the misleading no_checks_generated label.
    out = """SBY 17:10:30 [cover] ERROR: engine_0: Engine terminated without status.
make[1]: *** [cover/status] Error 1
make[1]: *** [insn_sltiu_ch0/status] Error 1
SBY 17:10:31 [insn_sltu_ch1] DONE (ERROR, rc=16)
make[1]: *** [insn_sltu_ch1/status] Error 16
SBY 17:11:11 [reg_ch0] DONE (PASS, rc=0)
make[1]: *** [reg_ch0/status] Error 1

Formal: 0 passed, 1 failed
Failed: no_checks_generated
"""
    assert _reclassify_no_checks_generated(out) == "make_failed_during_execution"


def test_only_genchecks_traceback_no_sby_output():
    # If genchecks.py raised before any SBY task launched, we should
    # NOT re-classify — the original label is correct.
    out = """=== genchecks ===
Traceback (most recent call last):
  File "../../checks/genchecks.py", line 7, in <module>
    config = parse_config()
ValueError: bad config

Formal: 0 passed, 1 failed
Failed: no_checks_generated
"""
    assert _reclassify_no_checks_generated(out) == "no_checks_generated"
