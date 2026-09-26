"""Tests for tools/bench/preflight.py."""
import json
import os
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


# --- free_disk_gb / MIN_FREE_GB ---

class _FakeStatvfs:
    def __init__(self, f_bavail, f_frsize):
        self.f_bavail = f_bavail
        self.f_frsize = f_frsize


def test_min_free_gb_is_30():
    assert preflight.MIN_FREE_GB == 30


def test_free_disk_gb_computes_from_statvfs(monkeypatch):
    # 100,000,000 blocks * 4096 bytes/block = 409.6 GB available.
    monkeypatch.setattr(
        os, "statvfs",
        lambda path: _FakeStatvfs(f_bavail=100_000_000, f_frsize=4096))
    assert preflight.free_disk_gb() == 409.6


def test_free_disk_gb_below_threshold(monkeypatch):
    # ~1 GB available should read well under MIN_FREE_GB.
    monkeypatch.setattr(
        os, "statvfs",
        lambda path: _FakeStatvfs(f_bavail=250_000, f_frsize=4096))
    gb = preflight.free_disk_gb()
    assert gb < preflight.MIN_FREE_GB
    assert round(gb, 1) == 1.0


def test_free_disk_gb_passes_path_through(monkeypatch):
    seen = {}

    def fake_statvfs(path):
        seen["path"] = path
        return _FakeStatvfs(f_bavail=100_000_000_000, f_frsize=4096)

    monkeypatch.setattr(os, "statvfs", fake_statvfs)
    preflight.free_disk_gb("/some/path")
    assert seen["path"] == "/some/path"
