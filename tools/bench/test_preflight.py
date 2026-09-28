"""Tests for tools/bench/preflight.py."""
import json
import os
import shutil
from pathlib import Path

from tools.bench import preflight


def test_required_tools_frozen():
    assert preflight.REQUIRED_TOOLS == ("verilator", "yosys", "sby", "bitwuzla")
    assert "nextpnr-himbaechel" not in preflight.DIGEST_TOOLS
    assert preflight.GOWIN_TOOLS == ("gw_sh", "GowinSynthesis")


def _fake_gowin(monkeypatch, root, content=b"gowin-a"):
    from tools.eval import gowin
    bindir = root / "IDE" / "bin"
    bindir.mkdir(parents=True, exist_ok=True)
    for t in preflight.GOWIN_TOOLS:
        (bindir / t).write_bytes(content)
    monkeypatch.setattr(gowin, "GOWIN_HOME", root)
    return bindir


def test_env_fingerprint_shape(monkeypatch):
    monkeypatch.setattr(shutil, "which",
                        lambda t: f"/fake/bin/{t}" if t != "sby" else None)
    fp = preflight.env_fingerprint()
    assert set(fp) == {"path", "harness_version", "tools", "tool_versions",
                       "tool_sha256", "toolchain_digest"}
    assert fp["tools"]["yosys"] == "/fake/bin/yosys"
    assert fp["tools"]["sby"] is None
    assert fp["tool_sha256"]["yosys"] is None  # fake path: unreadable, not guessed


def test_toolchain_digest_changes_with_a_binary(monkeypatch, tmp_path):
    for t in preflight.DIGEST_TOOLS:
        (tmp_path / t).write_bytes(b"build-a")
    monkeypatch.setattr(shutil, "which", lambda t: str(tmp_path / t))
    monkeypatch.setattr(preflight, "_version", lambda t: "v")
    bindir = _fake_gowin(monkeypatch, tmp_path / "gowin")
    before = preflight.toolchain_identity()["toolchain_digest"]
    (tmp_path / "verilator").write_bytes(b"build-b")
    mid = preflight.toolchain_identity()["toolchain_digest"]
    assert mid != before
    (bindir / "GowinSynthesis").write_bytes(b"gowin-b")
    assert preflight.toolchain_identity()["toolchain_digest"] != mid


def test_fingerprint_is_json_serializable(monkeypatch):
    monkeypatch.setattr(shutil, "which", lambda t: None)
    json.dumps(preflight.env_fingerprint())


def test_missing_tools_lists_only_absent(monkeypatch, tmp_path):
    monkeypatch.setattr(
        shutil, "which",
        lambda t: None if t in ("sby", "bitwuzla") else f"/fake/{t}")
    _fake_gowin(monkeypatch, tmp_path)
    assert preflight.missing_tools() == ["sby", "bitwuzla"]
    from tools.eval import gowin
    monkeypatch.setattr(gowin, "GOWIN_HOME", tmp_path / "absent")
    assert preflight.missing_tools() == ["sby", "bitwuzla", "gw_sh", "GowinSynthesis"]


def test_report_marks_missing(monkeypatch, tmp_path):
    from tools.eval import gowin
    monkeypatch.setattr(shutil, "which", lambda t: None)
    monkeypatch.setattr(gowin, "GOWIN_HOME", tmp_path / "absent")
    out = preflight.report()
    assert out.count("MISSING") == len(preflight.REQUIRED_TOOLS) + len(preflight.GOWIN_TOOLS)


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
