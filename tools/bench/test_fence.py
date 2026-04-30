"""Unit tests for the bench-fence path validator.

Mirrors the rules in tools/bench/extensions/bench-fence/index.ts.
If you change a rule in either, update both and adjust these tests.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from tools.bench.fence_validator import (
    DEFAULT_BASH_BLOCKLIST,
    DEFAULT_READ_ALLOW,
    DEFAULT_WRITE_ALLOW,
    FenceConfig,
    bash_contains_forbidden,
    is_read_allowed,
    is_write_allowed,
    rel_to_clone,
    validate_bash,
    validate_read,
    validate_write,
)


@pytest.fixture
def cfg(tmp_path: Path) -> FenceConfig:
    return FenceConfig(clone_root=str(tmp_path.resolve()))


# ---- rel_to_clone ------------------------------------------------------


def test_rel_to_clone_relative_path(cfg: FenceConfig):
    assert rel_to_clone("cores/bench/rtl/alu.sv", cfg.clone_root) == "cores/bench/rtl/alu.sv"


def test_rel_to_clone_absolute_inside(cfg: FenceConfig):
    abs_p = str(Path(cfg.clone_root) / "cores" / "bench" / "rtl" / "alu.sv")
    assert rel_to_clone(abs_p, cfg.clone_root) == "cores/bench/rtl/alu.sv"


def test_rel_to_clone_outside_returns_sentinel(cfg: FenceConfig):
    out = rel_to_clone("/etc/passwd", cfg.clone_root)
    assert out.startswith("__OUTSIDE__:")


def test_rel_to_clone_dotdot_escape(cfg: FenceConfig):
    out = rel_to_clone("../../../etc/passwd", cfg.clone_root)
    assert out.startswith("__OUTSIDE__:")


def test_rel_to_clone_clone_root_itself(cfg: FenceConfig):
    assert rel_to_clone(cfg.clone_root, cfg.clone_root) == ""


# ---- read allowlist ----------------------------------------------------


@pytest.mark.parametrize("path,expected", [
    ("cores/bench/rtl/alu.sv", True),
    ("cores/bench/test/test_alu.py", True),
    ("formal/run_all.sh", True),
    ("Makefile", True),
    ("CLAUDE.md", True),
    ("ARCHITECTURE.md", True),
    ("README.md", True),
    ("schemas/hypothesis.schema.json", True),
    ("tools/orchestrator.py", True),
    ("cores/baseline/rtl/alu.sv", False),
    ("cores/v1/rtl/alu.sv", False),
    ("cores/v2/anything", False),
    ("docs/blueprints/foo.md", False),
    ("docs/superpowers/specs/anything.md", False),
    ("bench/results.jsonl", False),
])
def test_is_read_allowed(cfg: FenceConfig, path: str, expected: bool):
    assert is_read_allowed(path, cfg) is expected


def test_validate_read_returns_reason_for_baseline(cfg: FenceConfig):
    ok, reason = validate_read("cores/baseline/rtl/alu.sv", cfg)
    assert ok is False
    assert reason is not None
    assert "outside the benchmark scope" in reason
    assert "cores/baseline" in reason or "cores/bench" in reason


def test_validate_read_allows_bench(cfg: FenceConfig):
    ok, reason = validate_read("cores/bench/rtl/alu.sv", cfg)
    assert ok is True
    assert reason is None


def test_validate_read_blocks_outside_clone(cfg: FenceConfig):
    ok, reason = validate_read("/etc/passwd", cfg)
    assert ok is False
    assert reason is not None


# ---- write allowlist ---------------------------------------------------


@pytest.mark.parametrize("path,expected", [
    ("cores/bench/rtl/alu.sv", True),
    ("cores/bench/rtl/new_file.sv", True),
    ("cores/bench/test/test_foo.py", True),
    ("cores/bench/experiments/hypotheses/h.yaml", True),
    ("cores/bench/implementation_notes.md", True),
    ("cores/baseline/rtl/alu.sv", False),
    ("cores/v1/rtl/alu.sv", False),
    ("Makefile", False),                # write-deny on Makefile
    ("CLAUDE.md", False),                # write-deny on root .md
    ("formal/wrapper.sv", False),
    ("schemas/hypothesis.schema.json", False),
    ("tools/orchestrator.py", False),
    ("bench/results.jsonl", False),
])
def test_is_write_allowed(cfg: FenceConfig, path: str, expected: bool):
    assert is_write_allowed(path, cfg) is expected


def test_validate_write_blocks_other_cores(cfg: FenceConfig):
    ok, reason = validate_write("cores/v1/rtl/foo.sv", cfg)
    assert ok is False
    assert reason is not None
    assert "outside the benchmark scope" in reason


# ---- bash blocklist ----------------------------------------------------


@pytest.mark.parametrize("cmd,is_blocked", [
    # Blocked
    ("cat cores/baseline/rtl/alu.sv", True),
    ("git checkout main -- foo", True),
    ("git fetch origin", True),
    ("git log -p", True),
    ("git show main:cores/foo", True),
    ("less cores/v1/rtl/alu.sv", True),
    # Allowed
    ("verilator --lint-only cores/bench/rtl/*.sv", False),
    ("bash formal/run_all.sh", False),
    ("python3 tools/eval/cosim.py", False),
    ("git status", False),
    ("git log --oneline -n 5", False),  # log without -p
    ("curl https://api.anthropic.com", False),
    ("ls cores/bench/rtl/", False),
])
def test_bash_blocklist(cfg: FenceConfig, cmd: str, is_blocked: bool):
    hit = bash_contains_forbidden(cmd, cfg)
    if is_blocked:
        assert hit is not None, f"expected '{cmd}' to be blocked but it wasn't"
    else:
        assert hit is None, f"expected '{cmd}' to be allowed but '{hit}' triggered"


def test_validate_bash_returns_specific_token(cfg: FenceConfig):
    ok, reason = validate_bash("cat cores/baseline/rtl/alu.sv", cfg)
    assert ok is False
    assert reason is not None
    assert "cores/baseline" in reason


def test_validate_bash_allows_legitimate(cfg: FenceConfig):
    ok, reason = validate_bash("verilator --lint-only cores/bench/rtl/*.sv", cfg)
    assert ok is True
    assert reason is None


# ---- config round-trip -------------------------------------------------


def test_fence_config_round_trip(tmp_path: Path):
    cfg = FenceConfig(
        clone_root=str(tmp_path.resolve()),
        read_allow=["cores/bench", "tools"],
        write_allow=["cores/bench/rtl"],
        bash_blocklist=["forbidden"],
    )
    dest = tmp_path / "fence.json"
    cfg.write(dest)
    loaded = FenceConfig.load(dest)
    assert loaded.clone_root == cfg.clone_root
    assert loaded.read_allow == cfg.read_allow
    assert loaded.write_allow == cfg.write_allow
    assert loaded.bash_blocklist == cfg.bash_blocklist


def test_default_lists_have_expected_anchors():
    """Sanity check that the defaults haven't drifted from the spec."""
    assert "cores/bench" in DEFAULT_READ_ALLOW
    assert "cores/bench/rtl" in DEFAULT_WRITE_ALLOW
    assert "cores/baseline" in DEFAULT_BASH_BLOCKLIST
    assert "cores/v1" in DEFAULT_BASH_BLOCKLIST
    assert "git checkout main" in DEFAULT_BASH_BLOCKLIST


# ---- regressions for the harness-bug fixes -----------------------------


def test_read_allowed_for_clone_root(cfg: FenceConfig):
    """Agents do `ls .` constantly to understand the workspace. Blocking it
    cripples them. The clone root itself must always be readable."""
    ok, _ = validate_read(".", cfg)
    assert ok is True
    ok, _ = validate_read(cfg.clone_root, cfg)
    assert ok is True


def test_read_allowed_for_ancestor_of_allowed_path(cfg: FenceConfig):
    """`ls cores` should work because `cores/bench` is allowed. Without
    this, the agent can't navigate into the allowed subdir."""
    ok, _ = validate_read("cores", cfg)
    assert ok is True
    ok, _ = validate_read("bench", cfg)  # bench/programs is allowed
    assert ok is True
    ok, _ = validate_read("test", cfg)   # test/cosim is allowed
    assert ok is True


def test_write_allowed_inside_per_iteration_worktree(cfg: FenceConfig):
    """The impl agent's cwd is cores/bench/worktrees/<hyp_id>/, so when it
    writes rtl/foo.sv from that cwd, the resolved path is
    cores/bench/worktrees/<hyp_id>/rtl/foo.sv. That should match the
    write_allow's `cores/bench/rtl` entry (after stripping the worktree
    prefix). Without this, every impl-phase write was being blocked."""
    # The worktree mirrors the full repo layout, so RTL lives at
    # <worktree>/cores/bench/rtl/, NOT <worktree>/rtl/.
    ok, _ = validate_write(
        "cores/bench/worktrees/hyp-20260430-001-r1s0/cores/bench/rtl/alu.sv", cfg)
    assert ok is True
    ok, _ = validate_write(
        "cores/bench/worktrees/hyp-XXX/cores/bench/test/test_pipeline.py", cfg)
    assert ok is True
    ok, _ = validate_write(
        "cores/bench/worktrees/hyp-XXX/cores/bench/implementation_notes.md", cfg)
    assert ok is True
    # Other cores still blocked even from inside a worktree
    ok, _ = validate_write(
        "cores/bench/worktrees/hyp-XXX/cores/baseline/rtl/alu.sv", cfg)
    assert ok is False


def test_relative_path_resolves_against_cwd(tmp_path):
    """Relative paths must resolve against the AGENT'S cwd, not the
    original clone root. Otherwise an impl agent at
    cwd=<clone>/cores/bench/worktrees/<id>/ saying `rtl/foo.sv` would
    incorrectly resolve to <clone>/rtl/foo.sv (NOT in write_allow)."""
    clone = str(tmp_path.resolve())
    worktree = str((tmp_path / "cores" / "bench" / "worktrees" / "hyp-001").resolve())
    rel = rel_to_clone("rtl/foo.sv", clone, cwd=worktree)
    assert rel == "cores/bench/worktrees/hyp-001/rtl/foo.sv"
    # Without cwd it falls back to clone root (legacy behavior)
    rel2 = rel_to_clone("rtl/foo.sv", clone)
    assert rel2 == "rtl/foo.sv"
