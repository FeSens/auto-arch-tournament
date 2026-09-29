"""Worktree metadata changes from parallel slot threads (V2 2.8.0 campaign,
incident 09): `git worktree add -b` read a sibling's half-written
.git/worktrees/<name>/commondir and died, losing a slot."""
import subprocess
import threading
import time

import pytest

from tools import worktree


def _repo(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    subprocess.run("git init -q -b main . && mkdir -p cores/bench/rtl && echo x > cores/bench/rtl/a.sv"
                   " && git add . && git -c user.name=t -c user.email=t@t commit -qm init",
                   shell=True, check=True)


def test_an_empty_sibling_commondir_kills_git_worktree_add(tmp_path, monkeypatch):
    # The failure mode itself, so the reason for the lock stays checkable.
    _repo(tmp_path, monkeypatch)
    worktree.create_worktree("hyp-x-r1s2", base_branch="main", target="bench")
    (tmp_path / ".git/worktrees/hyp-x-r1s2/commondir").write_text("")
    r = subprocess.run(["git", "worktree", "add", "-b", "b0", "wt0", "main"],
                       capture_output=True, text=True)
    assert r.returncode == 128 and "failed to read" in r.stderr and "commondir" in r.stderr


def test_slot_threads_never_run_worktree_git_commands_at_once(tmp_path, monkeypatch):
    _repo(tmp_path, monkeypatch)
    real_run = subprocess.run
    active = {"n": 0, "max": 0}
    guard = threading.Lock()

    def run(cmd, *a, **k):
        mutating = (isinstance(cmd, list) and cmd[:1] == ["git"]
                    and (cmd[1:2] in (["worktree"], ["branch"])))
        if mutating:
            with guard:
                active["n"] += 1
                active["max"] = max(active["max"], active["n"])
            time.sleep(0.02)  # widen the window a race would need
        try:
            return real_run(cmd, *a, **k)
        finally:
            if mutating:
                with guard:
                    active["n"] -= 1

    monkeypatch.setattr(worktree.subprocess, "run", run)
    errors = []

    def slot(s):
        try:
            for i in range(4):
                hid = f"hyp-20260929-00{s}-r{i}s{s}-hypgen"
                worktree.create_worktree(hid, base_branch="main", target="bench")
                worktree.destroy_worktree(hid, target="bench")
        except Exception as e:  # recorded for the assertion below
            errors.append(e)

    threads = [threading.Thread(target=slot, args=(s,)) for s in range(3)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert not errors
    assert active["max"] == 1


def test_a_failed_worktree_add_is_retried_from_a_clean_slate(tmp_path, monkeypatch, capsys):
    _repo(tmp_path, monkeypatch)
    real_run = subprocess.run
    calls = {"add": 0}

    def run(cmd, *a, **k):
        if isinstance(cmd, list) and cmd[:3] == ["git", "worktree", "add"]:
            calls["add"] += 1
            if calls["add"] == 1:
                return subprocess.CompletedProcess(
                    cmd, 128, "", "fatal: failed to read .git/worktrees/x/commondir: Success\n")
        return real_run(cmd, *a, **k)

    monkeypatch.setattr(worktree.subprocess, "run", run)
    monkeypatch.setattr(worktree.time, "sleep", lambda s: None)
    path = worktree.create_worktree("hyp-x-r2s0-hypgen", base_branch="main", target="bench")
    assert calls["add"] == 2
    assert (tmp_path / "cores/bench/worktrees/hyp-x-r2s0-hypgen/cores/bench/rtl/a.sv").exists()
    assert path.endswith("hyp-x-r2s0-hypgen")
    assert "attempt 1 of 3" in capsys.readouterr().out


def test_worktree_add_gives_up_after_three_attempts(tmp_path, monkeypatch):
    _repo(tmp_path, monkeypatch)
    real_run = subprocess.run

    def run(cmd, *a, **k):
        if isinstance(cmd, list) and cmd[:3] == ["git", "worktree", "add"]:
            return subprocess.CompletedProcess(cmd, 128, "", "fatal: nope\n")
        return real_run(cmd, *a, **k)

    monkeypatch.setattr(worktree.subprocess, "run", run)
    monkeypatch.setattr(worktree.time, "sleep", lambda s: None)
    with pytest.raises(subprocess.CalledProcessError):
        worktree.create_worktree("hyp-x-r3s0-hypgen", base_branch="main", target="bench")
