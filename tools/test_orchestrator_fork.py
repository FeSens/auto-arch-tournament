"""Fork-on-create semantics: cores/foo absent + BASE=bar → fork from bar."""
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest


# Common git -c flags for test commits. Disables signing because the
# user's real gitconfig may have SSH-key signing wired to a 1Password
# agent that prompts for biometric auth and hangs the test process.
_GIT_TEST_CFG = [
    "-c", "user.email=t@t",
    "-c", "user.name=t",
    "-c", "commit.gpgsign=false",
    "-c", "tag.gpgsign=false",
]


def _setup_repo(tmp: Path):
    """Create a minimal cores/baseline structure and init a git repo."""
    subprocess.run(["git", "init", "-b", "main"],
                   cwd=tmp, check=True, capture_output=True)
    subprocess.run(["git", *_GIT_TEST_CFG,
                    "commit", "--allow-empty", "-m", "init"],
                   cwd=tmp, check=True, capture_output=True)
    bl_rtl = tmp / "cores" / "baseline" / "rtl"
    bl_test = tmp / "cores" / "baseline" / "test"
    bl_rtl.mkdir(parents=True)
    bl_test.mkdir(parents=True)
    (bl_rtl / "core.sv").write_text("module core(); endmodule\n")
    (tmp / "cores" / "baseline" / "core.yaml").write_text(
        "name: baseline\nisa: rv32im\ntarget_fpga: x\ntargets: {}\ncurrent: {}\n"
    )
    (tmp / "cores" / "baseline" / "CORE_PHILOSOPHY.md").write_text("")
    (bl_test / "_helpers.py").write_text("# helpers\n")
    (bl_test / "conftest.py").write_text("# conftest\n")
    subprocess.run(["git", "add", "."], cwd=tmp, check=True, capture_output=True)
    subprocess.run(["git", *_GIT_TEST_CFG,
                    "commit", "-m", "seed baseline"],
                   cwd=tmp, check=True, capture_output=True)


def test_fork_creates_target_from_base(tmp_path):
    _setup_repo(tmp_path)
    # Import the function under test (lazy to avoid import-time path resolution).
    import sys
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from tools.orchestrator import fork_core

    # Headless mode (no TTY) so the philosophy prompt is skipped.
    fork_core(target="foo", base="baseline", repo_root=tmp_path, interactive=False)

    # Verify the new core's structure.
    foo = tmp_path / "cores" / "foo"
    assert (foo / "rtl" / "core.sv").exists()
    assert (foo / "test").is_dir()
    assert (foo / "core.yaml").exists()
    assert (foo / "CORE_PHILOSOPHY.md").exists()  # empty file from headless skip
    assert (foo / "CORE_PHILOSOPHY.md").read_text() == ""
    # core.yaml should have current: cleared but targets: carried.
    yaml_text = (foo / "core.yaml").read_text()
    assert "name: baseline" not in yaml_text  # name should be rewritten to foo
    assert "name: foo" in yaml_text
    # Verify test infra files were copied.
    assert (foo / "test" / "_helpers.py").exists()
    assert (foo / "test" / "conftest.py").exists()
    assert (foo / "test" / "_helpers.py").read_text() == "# helpers\n"
    # Verify fork was committed.
    log = subprocess.run(
        ["git", "log", "--oneline", "-1"],
        cwd=tmp_path, capture_output=True, text=True, check=True,
    ).stdout
    assert "feat: fork cores/foo from cores/baseline" in log


def test_fork_errors_if_target_exists(tmp_path):
    _setup_repo(tmp_path)
    (tmp_path / "cores" / "foo").mkdir()
    import sys
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from tools.orchestrator import fork_core

    with pytest.raises(SystemExit, match="already exists"):
        fork_core(target="foo", base="baseline", repo_root=tmp_path, interactive=False)


def test_active_branch_returns_per_target_branch(tmp_path):
    """Regression: orchestrator must fork hypothesis worktrees off the loop's
    active branch (core-<target> in WORKTREE=1 mode), not from a hardcoded
    'main'. With main=ab15c6a and core-maxperf carrying the freshly-forked
    cores/maxperf/, hardcoding 'main' produced empty hypothesis worktrees
    that confused the codex agent into editing other cores."""
    _setup_repo(tmp_path)
    subprocess.run(["git", "checkout", "-b", "core-maxperf"],
                   cwd=tmp_path, check=True, capture_output=True)
    import sys
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from tools.orchestrator import _active_branch

    assert _active_branch(repo_root=tmp_path) == "core-maxperf"


def test_active_branch_rejects_detached_head(tmp_path):
    _setup_repo(tmp_path)
    sha = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=tmp_path, capture_output=True, text=True, check=True,
    ).stdout.strip()
    subprocess.run(["git", "checkout", "--detach", sha],
                   cwd=tmp_path, check=True, capture_output=True)
    import sys
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from tools.orchestrator import _active_branch

    with pytest.raises(SystemExit, match="detached HEAD"):
        _active_branch(repo_root=tmp_path)
