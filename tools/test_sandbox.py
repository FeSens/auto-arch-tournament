"""tools/sandbox.py: contract fingerprint + ignored-output purge."""
import subprocess
from pathlib import Path

import pytest

from tools import sandbox
from tools.sandbox import (
    purge_ignored_outputs, snapshot_changes, take_snapshot,
)


def _git(cwd, *args):
    subprocess.run(["git", "-C", str(cwd), *args], check=True,
                   capture_output=True)


def _repo(root: Path) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    _git(root, "init", "-q")
    _git(root, "config", "user.email", "t@t")
    _git(root, "config", "user.name", "t")
    _git(root, "config", "commit.gpgsign", "false")
    return root


@pytest.fixture
def checkout(tmp_path, monkeypatch):
    """A main checkout with contract files, a gitignore, and a
    riscv-formal git checkout of its own."""
    monkeypatch.setattr(sandbox, "EVAL_TOOLS", ())
    root = _repo(tmp_path / "main")
    (root / "tools").mkdir()
    (root / "tools" / "fpga.py").write_text("CRC = 1\n")
    (root / "formal").mkdir()
    (root / "formal" / "checks.cfg").write_text("[options]\n")
    (root / "bench" / "programs").mkdir(parents=True)
    (root / "bench" / "programs" / "crt0.S").write_text("_start:\n")
    (root / "cores" / "t" / "rtl").mkdir(parents=True)
    (root / "cores" / "t" / "rtl" / "core.sv").write_text("module core; endmodule\n")
    (root / ".gitignore").write_text(
        "formal/riscv-formal\n*.elf\n.toolchain/\n__pycache__/\n"
        "generated/\n.agent.log\nimplementation_notes.md\n")
    _git(root, "add", "-A")
    _git(root, "commit", "-qm", "init")
    rf = _repo(root / "formal" / "riscv-formal")
    (rf / "checks").mkdir()
    (rf / "checks" / "genchecks.py").write_text("print('gen')\n")
    _git(rf, "add", "-A")
    _git(rf, "commit", "-qm", "rf")
    return root


def test_snapshot_clean_when_nothing_changes(checkout):
    before = take_snapshot(checkout)
    assert snapshot_changes(before, take_snapshot(checkout)) == []


def test_snapshot_flags_contract_edit_in_main_checkout(checkout):
    before = take_snapshot(checkout)
    (checkout / "tools" / "fpga.py").write_text("CRC = 2\n")
    assert snapshot_changes(before, take_snapshot(checkout)) == ["tools/fpga.py"]


def test_snapshot_flags_new_and_deleted_contract_files(checkout):
    before = take_snapshot(checkout)
    (checkout / "tools" / "evil.py").write_text("x = 1\n")
    (checkout / "formal" / "checks.cfg").unlink()
    assert snapshot_changes(before, take_snapshot(checkout)) == [
        "formal/checks.cfg", "tools/evil.py"]


def test_snapshot_ignores_non_contract_paths(checkout):
    before = take_snapshot(checkout)
    (checkout / "cores" / "t" / "rtl" / "core.sv").write_text("// edited\n")
    (checkout / "cores" / "t" / "LESSONS.md").write_text("- lesson\n")
    assert snapshot_changes(before, take_snapshot(checkout)) == []


def test_snapshot_flags_riscv_formal_edit_and_commit(checkout):
    rf = checkout / "formal" / "riscv-formal"
    before = take_snapshot(checkout)
    (rf / "checks" / "genchecks.py").write_text("print('pass')\n")
    assert snapshot_changes(before, take_snapshot(checkout)) == [
        "riscv-formal/checks/genchecks.py"]
    # Committing the tamper must not hide it.
    _git(rf, "commit", "-qam", "tamper")
    assert "riscv-formal@HEAD" in snapshot_changes(before, take_snapshot(checkout))


def test_snapshot_tolerates_riscv_formal_staging_dirs(checkout):
    before = take_snapshot(checkout)
    staging = checkout / "formal" / "riscv-formal" / "cores" / "t-1234" / "checks"
    staging.mkdir(parents=True)
    (staging / "insn_add_ch0.sby").write_text("[tasks]\n")
    assert snapshot_changes(before, take_snapshot(checkout)) == []


def test_snapshot_riscv_formal_without_git_hashes_generator(checkout):
    import shutil
    rf = checkout / "formal" / "riscv-formal"
    shutil.rmtree(rf / ".git")
    before = take_snapshot(checkout)
    assert "riscv-formal/checks/genchecks.py" in before
    (rf / "checks" / "genchecks.py").write_text("print('pass')\n")
    assert snapshot_changes(before, take_snapshot(checkout)) == [
        "riscv-formal/checks/genchecks.py"]


def test_snapshot_flags_toolchain_binary_swap(checkout, tmp_path, monkeypatch):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    tool = bindir / "sby"
    tool.write_text("#!/bin/sh\nexit 0\n")
    tool.chmod(0o755)
    import os
    monkeypatch.setenv("PATH", f"{bindir}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setattr(sandbox, "EVAL_TOOLS", ("sby",))
    before = take_snapshot(checkout)
    tool.write_text("#!/bin/sh\necho 'DONE (PASS'\n")
    assert snapshot_changes(before, take_snapshot(checkout)) == ["tool:sby"]


def test_purge_removes_planted_build_inputs_and_keeps_allowlist(checkout):
    wt = checkout
    (wt / "bench" / "programs" / "coremark.elf").write_bytes(b"\x7fELF fake")
    fake_bin = wt / ".toolchain" / "oss-cad-suite" / "bin"
    fake_bin.mkdir(parents=True)
    (fake_bin / "sby").write_text("#!/bin/sh\n")
    (wt / "tools" / "__pycache__").mkdir()
    (wt / "tools" / "__pycache__" / "fpga.cpython-313.pyc").write_bytes(b"x")
    (wt / "cores" / "t" / "generated").mkdir()
    (wt / "cores" / "t" / "generated" / "synth.json").write_text("{}")
    (wt / ".agent.log").write_text("transcript")
    (wt / "implementation_notes.md").write_text("notes")

    purged = purge_ignored_outputs(wt, target="t")

    assert not (wt / "bench" / "programs" / "coremark.elf").exists()
    assert not (wt / ".toolchain").exists()
    assert not (wt / "tools" / "__pycache__").exists()
    assert not (wt / "cores" / "t" / "generated").exists()
    assert (wt / ".agent.log").exists()
    assert (wt / "implementation_notes.md").exists()
    # The riscv-formal checkout (a symlink in real worktrees) survives.
    assert (wt / "formal" / "riscv-formal" / "checks" / "genchecks.py").exists()
    assert "bench/programs/coremark.elf" in purged


def test_purge_unlinks_symlinks_without_following(checkout, tmp_path):
    outside = tmp_path / "outside.elf"
    outside.write_text("keep")
    planted = checkout / "bench" / "programs" / "coremark.elf"
    planted.symlink_to(outside)
    purge_ignored_outputs(checkout, target="t")
    assert not planted.is_symlink()
    assert outside.read_text() == "keep"


# --- delta-based sandbox checks (dirty_state / changed_since / revert_paths)

from tools.sandbox import (  # noqa: E402
    changed_since, dirty_state, is_harness_output, revert_paths,
)


def _allow_rtl(p):
    return p.startswith("cores/t/rtl/")


def test_changed_since_ignores_pre_existing_dirt(checkout):
    (checkout / "tools" / "fpga.py").write_text("maintainer WIP\n")
    (checkout / "tools" / "wip_new.py").write_text("wip\n")
    before = dirty_state(checkout)
    (checkout / "cores" / "t" / "rtl" / "core.sv").write_text("// agent\n")
    assert changed_since(before, dirty_state(checkout), _allow_rtl) == []


def test_changed_since_flags_agent_edit_of_already_dirty_file(checkout):
    (checkout / "tools" / "fpga.py").write_text("maintainer WIP\n")
    before = dirty_state(checkout)
    (checkout / "tools" / "fpga.py").write_text("maintainer WIP\nCRC = 0\n")
    assert changed_since(before, dirty_state(checkout), _allow_rtl) == ["tools/fpga.py"]


def test_harness_outputs_tolerated_without_gitignore(checkout):
    before = dirty_state(checkout)
    for rel in (".agent.impl.log", "cores/t/experiments/hypotheses/.agent.h-1.last",
                "formal/last_run-4242.log", "cores/t/experiments/run_summary.json",
                "cores/t/experiments/.scribe.log", "tools/x.cpython-313.pyc"):
        f = checkout / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text("harness")
    assert changed_since(before, dirty_state(checkout), _allow_rtl) == []


def test_harness_output_patterns_do_not_cover_contract_files():
    for rel in ("tools/eval/fpga.py", "formal/run_all.sh", "formal/checks.cfg",
                "test/cosim/main.cpp", "bench/programs/coremark.elf",
                "cores/t/experiments/log.jsonl", "cores/t/rtl/core.sv"):
        assert not is_harness_output(rel), rel


def test_revert_paths_restores_agent_changes_but_not_prior_wip(checkout):
    (checkout / "tools" / "fpga.py").write_text("maintainer WIP\n")
    before = dirty_state(checkout)
    # Agent: edits a clean tracked file, adds a file, edits the WIP file.
    (checkout / "formal" / "checks.cfg").write_text("[options]\nweakened\n")
    (checkout / "tools" / "planted.py").write_text("x\n")
    (checkout / "tools" / "fpga.py").write_text("agent overwrote WIP\n")
    breaches = changed_since(before, dirty_state(checkout), _allow_rtl)
    left = revert_paths(breaches, before, checkout)
    assert (checkout / "formal" / "checks.cfg").read_text() == "[options]\n"
    assert not (checkout / "tools" / "planted.py").exists()
    # Pre-existing WIP is never reset to HEAD; it is reported instead.
    assert left == ["tools/fpga.py"]
    assert (checkout / "tools" / "fpga.py").read_text() == "agent overwrote WIP\n"


def test_offlimits_changes_uses_harness_tolerance(checkout):
    from tools.orchestrator import allowed_patterns_for, offlimits_changes
    (checkout / "formal" / "last_run-99.log").write_text("log")
    (checkout / "cores" / "t" / "rtl" / "core.sv").write_text("// ok\n")
    assert offlimits_changes(str(checkout), allowed_patterns_for("t")) == []
    (checkout / "formal" / "checks.cfg").write_text("weakened\n")
    assert offlimits_changes(str(checkout), allowed_patterns_for("t")) == [
        "formal/checks.cfg"]
