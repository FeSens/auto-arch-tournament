"""Tests for tools/bench/preflight.py."""
import json
import shutil
from pathlib import Path

from tools.bench import preflight


def test_required_tools_frozen():
    assert preflight.REQUIRED_TOOLS == (
        "verilator", "yosys", "nextpnr-himbaechel", "sby", "bitwuzla",
    )


def test_env_fingerprint_shape(monkeypatch):
    monkeypatch.setattr(shutil, "which",
                        lambda t: f"/fake/bin/{t}" if t != "sby" else None)
    fp = preflight.env_fingerprint()
    assert set(fp) == {"path", "tools"}
    assert fp["tools"]["yosys"] == "/fake/bin/yosys"
    assert fp["tools"]["sby"] is None


def test_fingerprint_is_json_serializable(monkeypatch):
    monkeypatch.setattr(shutil, "which", lambda t: None)
    json.dumps(preflight.env_fingerprint())


def test_missing_tools_lists_only_absent(monkeypatch):
    monkeypatch.setattr(
        shutil, "which",
        lambda t: None if t in ("sby", "bitwuzla") else f"/fake/{t}")
    assert preflight.missing_tools() == ["sby", "bitwuzla"]


def test_report_marks_missing(monkeypatch):
    monkeypatch.setattr(shutil, "which", lambda t: None)
    out = preflight.report()
    assert out.count("MISSING") == len(preflight.REQUIRED_TOOLS)
