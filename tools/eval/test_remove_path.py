"""remove_path: harness deletions of agent-written trees must not fail
silently (a surviving dir broke a whole run, and a surviving artifact would
reach the eval)."""
import os

import pytest

from tools.eval._subprocess import remove_path


def test_removes_files_trees_and_symlinks(tmp_path):
    (tmp_path / "d" / "e").mkdir(parents=True)
    (tmp_path / "d" / "e" / "f").write_text("x")
    (tmp_path / "l").symlink_to(tmp_path / "d")
    remove_path(tmp_path / "l")
    assert (tmp_path / "d" / "e" / "f").exists()     # link removed, not followed
    remove_path(tmp_path / "d")
    assert not (tmp_path / "d").exists()
    remove_path(tmp_path / "missing")                # absent is fine


def test_raises_when_something_survives(tmp_path, monkeypatch):
    monkeypatch.delenv("HWE_AGENT_USER", raising=False)
    locked = tmp_path / "gen" / ".xdg"
    locked.mkdir(parents=True)
    (locked / "sock").write_text("x")
    os.chmod(locked, 0)
    try:
        with pytest.raises(RuntimeError, match="cannot remove"):
            remove_path(tmp_path / "gen")
        remove_path(tmp_path / "gen", must=False)    # tolerated when asked
    finally:
        os.chmod(locked, 0o700)
