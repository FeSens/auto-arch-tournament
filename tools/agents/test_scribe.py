"""Tests for the scribe agent: prompt construction, sandbox, append-only
contract, and return-value semantics.

Agent invocation itself is stubbed — we don't spin up codex/claude in unit
tests. The stub mimics whatever the real agent would have written by
patching `run_agent_streaming` to perform a side-effect on the filesystem
and return (rc, timed_out).
"""
import subprocess
from pathlib import Path

import pytest

from tools.agents import scribe


def _git_init(repo: Path):
    """Initialize a git repo with one initial commit so `git status` works."""
    subprocess.run(["git", "init"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
                    "commit", "--allow-empty", "-m", "init"],
                   cwd=repo, check=True, capture_output=True)


@pytest.fixture
def repo(tmp_path, monkeypatch):
    """Repo with cores/foo/ committed so it is no longer "untracked" — mirrors
    production where each core has core.yaml, rtl/, etc. tracked. Without
    this, `git status --porcelain` would flag the bare cores/ tree itself
    and the sandbox check would treat it as off-limits."""
    _git_init(tmp_path)
    (tmp_path / "cores" / "foo").mkdir(parents=True)
    # Placeholder tracked file so cores/foo/ is part of HEAD.
    (tmp_path / "cores" / "foo" / "core.yaml").write_text("name: foo\n")
    subprocess.run(["git", "add", "cores/foo/core.yaml"],
                   cwd=tmp_path, check=True, capture_output=True)
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
                    "commit", "-m", "seed core foo"],
                   cwd=tmp_path, check=True, capture_output=True)
    monkeypatch.chdir(tmp_path)
    return tmp_path


def _entry(**over):
    return {
        "id": "hyp-test-001",
        "title": "test hypothesis",
        "category": "structural",
        "outcome": "regression",
        "delta_pct": -2.5,
        "error": None,
        "implementation_notes": "did the thing",
        "hypothesis": {
            "motivation": "m",
            "hypothesis": "h",
            "expected_impact": "ei",
            "changes": [],
        },
        **over,
    }


def test_build_prompt_has_required_sections(repo):
    p = scribe._build_prompt(_entry(), "diff goes here", "foo")
    assert "cores/foo/LESSONS.md" in p
    assert "outcome:   regression" in p
    assert "delta_pct: -2.50%" in p
    assert "did the thing" in p
    assert "diff goes here" in p
    # Format spec for the bullet must be present and unambiguous.
    assert "YYYY-MM-DD <id> (<outcome>" in p
    # Skip-conditions must be communicated.
    assert "SKIP" in p


def test_build_prompt_truncates_long_diff(repo):
    huge = "x" * (scribe.DIFF_MAX_CHARS + 5000)
    p = scribe._build_prompt(_entry(), huge, "foo")
    assert "[... diff truncated ...]" in p
    # The prompt must contain at most max_chars + truncation marker, not the full huge string.
    assert p.count("x") <= scribe.DIFF_MAX_CHARS + 100


def test_build_prompt_handles_missing_fields(repo):
    """A broken-from-hypothesis-gen entry has no hypothesis sub-object and
    no implementation_notes. Prompt build must not crash."""
    minimal = {
        "id": "hyp-fail-001",
        "title": "(slot 0 hypothesis-gen failed)",
        "category": "micro_opt",
        "outcome": "broken",
        "error": "hypothesis_gen_failed: timeout",
    }
    p = scribe._build_prompt(minimal, "", "foo")
    assert "(no notes)" in p
    assert "(no diff captured)" in p
    assert "(none)" in p  # motivation / hypothesis / expected_impact


def test_run_scribe_returns_appended_line(repo, monkeypatch):
    """Happy path: the agent appends a bullet; run_scribe_agent returns
    exactly that line."""
    def fake_run(cmd, cwd, log_path, timeout_sec, mode="w", provider=None):
        # Simulate the agent appending one bullet to LESSONS.md.
        path = scribe.lessons_path("foo")
        path.write_text("- 2026-04-29 hyp-test-001 (regression, -2.50%): example lesson\n")
        return (0, False)
    monkeypatch.setattr(scribe, "run_agent_streaming", fake_run)

    result = scribe.run_scribe_agent(_entry(), "diff", "foo")
    assert result is not None
    assert "example lesson" in result


def test_run_scribe_returns_none_when_agent_skips(repo, monkeypatch):
    """Skip path: agent writes nothing; return None."""
    def fake_run(cmd, cwd, log_path, timeout_sec, mode="w", provider=None):
        return (0, False)  # no file write
    monkeypatch.setattr(scribe, "run_agent_streaming", fake_run)

    result = scribe.run_scribe_agent(_entry(), "diff", "foo")
    assert result is None


def test_run_scribe_appends_to_existing_file(repo, monkeypatch):
    """When LESSONS.md already has prior content, only the newly appended
    line is returned — not the full file."""
    path = scribe.lessons_path("foo")
    path.write_text("- 2026-04-28 hyp-old (improvement, +1.0%): prior lesson\n")
    prior = path.read_text()

    def fake_run(cmd, cwd, log_path, timeout_sec, mode="w", provider=None):
        with path.open("a") as f:
            f.write("- 2026-04-29 hyp-test-001 (regression, -2.50%): new lesson\n")
        return (0, False)
    monkeypatch.setattr(scribe, "run_agent_streaming", fake_run)

    result = scribe.run_scribe_agent(_entry(), "diff", "foo")
    assert result is not None
    assert "new lesson" in result
    # Crucially: the prior lesson must NOT be in the return value.
    assert "prior lesson" not in result


def test_run_scribe_reverts_offlimits_writes(repo, monkeypatch):
    """If the scribe writes to anything other than cores/foo/LESSONS.md,
    those writes get reverted and the call raises PermissionError. The
    legitimate LESSONS.md write is allowed to land or be reverted with the
    raise — we just check the off-limits file doesn't survive."""
    rogue = repo / "rogue.txt"

    def fake_run(cmd, cwd, log_path, timeout_sec, mode="w", provider=None):
        rogue.write_text("agent went off-script")
        scribe.lessons_path("foo").write_text("- legit bullet\n")
        return (0, False)
    monkeypatch.setattr(scribe, "run_agent_streaming", fake_run)

    with pytest.raises(PermissionError, match="off-limits"):
        scribe.run_scribe_agent(_entry(), "diff", "foo")
    assert not rogue.exists()


def test_run_scribe_reverts_rewrite_of_lessons(repo, monkeypatch):
    """A scribe that rewrites LESSONS.md (replacing prior content) violates
    the append-only contract — the file is restored and PermissionError
    raised, so we don't lose accumulated history."""
    path = scribe.lessons_path("foo")
    original = "- 2026-04-28 hyp-old (improvement, +1.0%): prior lesson\n"
    path.write_text(original)

    def fake_run(cmd, cwd, log_path, timeout_sec, mode="w", provider=None):
        # Replace, not append. (Notice no leading copy of original.)
        path.write_text("- new content but the old stuff is gone\n")
        return (0, False)
    monkeypatch.setattr(scribe, "run_agent_streaming", fake_run)

    with pytest.raises(PermissionError, match="append"):
        scribe.run_scribe_agent(_entry(), "diff", "foo")
    # Original content must still be on disk after the revert.
    assert path.read_text() == original


def test_run_scribe_raises_on_timeout(repo, monkeypatch):
    def fake_run(cmd, cwd, log_path, timeout_sec, mode="w", provider=None):
        return (-9, True)
    monkeypatch.setattr(scribe, "run_agent_streaming", fake_run)

    with pytest.raises(TimeoutError):
        scribe.run_scribe_agent(_entry(), "diff", "foo")


def test_run_scribe_raises_on_nonzero_exit(repo, monkeypatch):
    def fake_run(cmd, cwd, log_path, timeout_sec, mode="w", provider=None):
        return (1, False)
    monkeypatch.setattr(scribe, "run_agent_streaming", fake_run)

    with pytest.raises(subprocess.CalledProcessError):
        scribe.run_scribe_agent(_entry(), "diff", "foo")
