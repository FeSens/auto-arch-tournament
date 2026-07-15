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
