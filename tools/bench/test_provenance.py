import subprocess

from tools.bench.runner import provenance


def _git(cwd, *args):
    subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True)


def test_provenance_records_commits_and_dirty(tmp_path):
    _git(tmp_path, "init", "-q")
    _git(tmp_path, "config", "user.email", "t@t")
    _git(tmp_path, "config", "user.name", "t")
    (tmp_path / "tools").mkdir()
    (tmp_path / "tools" / "a.py").write_text("")
    _git(tmp_path, "add", "-A")
    _git(tmp_path, "-c", "commit.gpgsign=false", "commit", "-qm", "init")
    _git(tmp_path, "tag", "fixture-v1")
    head = subprocess.run(["git", "-C", str(tmp_path), "rev-parse", "HEAD"],
                          capture_output=True, text=True).stdout.strip()

    p = provenance(tmp_path, "fixture-v1")
    assert p == {"fixture_ref": "fixture-v1", "fixture_commit": head,
                 "runner_commit": head, "runner_dirty": False}

    (tmp_path / "tools" / "a.py").write_text("x = 1\n")
    assert provenance(tmp_path, "fixture-v1")["runner_dirty"] is True
    assert provenance(tmp_path, "no-such-ref")["fixture_commit"] is None
