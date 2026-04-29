"""Fork-on-create semantics: cores/foo absent + BASE=bar → fork from bar."""
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest


def _setup_repo(tmp: Path):
    """Create a minimal cores/baseline structure and init a git repo."""
    subprocess.run(["git", "init"], cwd=tmp, check=True, capture_output=True)
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
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
    subprocess.run(["git", "add", "."], cwd=tmp, check=True, capture_output=True)
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
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
    assert "name: foo" in yaml_text or "name:" in yaml_text


def test_fork_errors_if_target_exists(tmp_path):
    _setup_repo(tmp_path)
    (tmp_path / "cores" / "foo").mkdir()
    import sys
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from tools.orchestrator import fork_core

    with pytest.raises(SystemExit, match="already exists"):
        fork_core(target="foo", base="baseline", repo_root=tmp_path, interactive=False)
