"""watch_publish refuses to render the public site from uncommitted code."""
import json
import subprocess

import pytest

from tools.site import watch_publish


def _git(cwd, *args):
    subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True)


@pytest.fixture
def repo(tmp_path, monkeypatch):
    _git(tmp_path, "init", "-q")
    _git(tmp_path, "config", "user.email", "t@t")
    _git(tmp_path, "config", "user.name", "t")
    (tmp_path / "tools" / "site").mkdir(parents=True)
    (tmp_path / "tools" / "site" / "build.py").write_text("X = 1\n")
    (tmp_path / "tools" / "bench").mkdir()
    (tmp_path / "tools" / "bench" / "report.py").write_text("Y = 1\n")
    (tmp_path / "bench").mkdir()
    (tmp_path / "bench" / "results.jsonl").write_text("")
    _git(tmp_path, "add", "-A")
    _git(tmp_path, "-c", "commit.gpgsign=false", "commit", "-qm", "init")
    monkeypatch.setattr(watch_publish, "REPO", tmp_path)
    return tmp_path


def test_generator_changes_clean(repo):
    assert watch_publish.generator_changes() == []


def test_generator_changes_lists_modified_and_new(repo):
    (repo / "tools" / "site" / "build.py").write_text("X = 2\n")
    (repo / "tools" / "site" / "new.py").write_text("")
    (repo / "tools" / "bench" / "report.py").write_text("Y = 2\n")
    assert sorted(watch_publish.generator_changes()) == [
        "tools/bench/report.py", "tools/site/build.py", "tools/site/new.py"]


def test_publish_once_defers_on_dirty_generator(repo, monkeypatch):
    model = next(iter(watch_publish.EXPECTED_REPS))
    results = repo / "bench" / "results.jsonl"
    results.write_text(json.dumps({"model": model, "rep": 1, "status": "done"}) + "\n")
    (repo / "tools" / "site" / "build.py").write_text("X = 2\n")
    ran = []
    monkeypatch.setattr(watch_publish, "_run", lambda *a, **k: ran.append(a))
    with pytest.raises(RuntimeError, match="uncommitted"):
        watch_publish.publish_once(results)
    assert ran == []  # nothing rendered, committed, or pushed
