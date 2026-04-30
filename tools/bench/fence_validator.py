"""Python mirror of the bench-fence TypeScript extension validator.

The TypeScript file (tools/bench/extensions/bench-fence/index.ts) is
what pi loads and runs at benchmark time. This Python file exists so:
  - the runner can render bench-fence.config.json with default
    allowlists (no need to duplicate rule lists in two files)
  - unit tests can exercise the same validation rules without a Node
    runtime

If you change the rules in one file, mirror the change in the other.
The functions are pure: given a path / command and a config, return
either (allow, None) or (deny, reason).
"""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


# Default allowlists — used by the runner to render bench-fence.config.json
# per clone. The rules are also the spec source of truth; tests assert that
# the rendered config matches DEFAULT_*.
DEFAULT_READ_ALLOW = [
    "cores/bench",
    "formal",
    "fpga",
    "bench/programs",
    "test/cosim",
    "tools",
    "schemas",
    "Makefile",
    "CLAUDE.md",
    "ARCHITECTURE.md",
    "README.md",
    ".gitignore",
    ".agent.last",
    ".agent.log",
    ".pi-sessions",
    ".pi/extensions/bench-fence",
]

DEFAULT_WRITE_ALLOW = [
    "cores/bench/rtl",
    "cores/bench/test",
    "cores/bench/experiments",
    "cores/bench/implementation_notes.md",
    # Build artifacts the orchestrator needs to land:
    "cores/bench/obj_dir",
    "cores/bench/generated",
    "cores/bench/sim_build",
    "formal/work",
    "obj_dir",
    "sim_build",
    ".pi-sessions",
    ".agent.last",
    ".agent.log",
]

DEFAULT_BASH_BLOCKLIST = [
    "cores/baseline",
    "cores/v1",
    "cores/bench-",       # any future bench-v2, bench-v3, etc.
    "/baseline/",
    "/v1/",
    "git checkout main",
    "git checkout master",
    "git fetch",
    "git log -p",
    "git log --patch",
    "git show main",
    "git show master",
    "git stash",
    ".git/objects",
    "git reflog",
    "git cat-file",
]


@dataclass
class FenceConfig:
    clone_root: str
    read_allow: list[str] = field(default_factory=lambda: list(DEFAULT_READ_ALLOW))
    write_allow: list[str] = field(default_factory=lambda: list(DEFAULT_WRITE_ALLOW))
    bash_blocklist: list[str] = field(default_factory=lambda: list(DEFAULT_BASH_BLOCKLIST))

    def to_json(self) -> dict[str, Any]:
        return {
            "clone_root": self.clone_root,
            "read_allow": self.read_allow,
            "write_allow": self.write_allow,
            "bash_blocklist": self.bash_blocklist,
        }

    def write(self, dest: Path) -> None:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(json.dumps(self.to_json(), indent=2) + "\n")

    @classmethod
    def load(cls, src: Path) -> "FenceConfig":
        data = json.loads(src.read_text())
        return cls(
            clone_root=data["clone_root"],
            read_allow=list(data.get("read_allow", DEFAULT_READ_ALLOW)),
            write_allow=list(data.get("write_allow", DEFAULT_WRITE_ALLOW)),
            bash_blocklist=list(data.get("bash_blocklist", DEFAULT_BASH_BLOCKLIST)),
        )


_OUTSIDE = "__OUTSIDE__:"

# Per-iteration worktrees live at cores/bench/worktrees/<hyp_id>/.
# When the impl agent edits rtl/foo.sv from cwd=worktree, the absolute
# path resolves to <clone>/cores/bench/worktrees/<id>/rtl/foo.sv.
# Strip the prefix so the inner path matches the same allow lists.
_WORKTREE_RE = re.compile(r"^cores/bench/worktrees/[^/]+/(.+)$")


def rel_to_clone(target: str, clone_root: str, cwd: str | None = None) -> str:
    """Resolve `target` relative to the agent's CWD (or clone_root if no
    cwd given), normalize, and return the rel-path from clone_root.

    Relative paths inside the impl phase must resolve against the
    sub-worktree's path, not the original clone root, otherwise
    `rtl/foo.sv` mistakenly resolves to `<clone>/rtl/foo.sv` — which
    isn't in any allow list.
    """
    clone_root = os.path.normpath(clone_root)
    base = os.path.normpath(cwd) if cwd else clone_root
    abs_p = (target if os.path.isabs(target)
             else os.path.normpath(os.path.join(base, target)))
    abs_p = os.path.normpath(abs_p)
    if abs_p == clone_root:
        return ""
    sep = os.sep
    if abs_p.startswith(clone_root + sep):
        return abs_p[len(clone_root) + 1:]
    return _OUTSIDE + abs_p


def _strip_worktree(rel: str) -> str:
    m = _WORKTREE_RE.match(rel)
    return m.group(1) if m else rel


def _matches_prefix(rel: str, prefix: str) -> bool:
    if rel == prefix:
        return True
    if prefix.endswith("/"):
        return rel.startswith(prefix)
    return rel.startswith(prefix + "/")


def is_read_allowed(rel: str, cfg: FenceConfig) -> bool:
    if rel.startswith(_OUTSIDE):
        return False
    # Always allow the clone root (empty rel) — agents do `ls .` constantly.
    if rel == "":
        return True
    inner = _strip_worktree(rel)
    for p in cfg.read_allow:
        if _matches_prefix(rel, p) or _matches_prefix(inner, p):
            return True
        # Allow any ancestor of an allowed path so `ls cores` works when
        # `cores/bench` is allowed (otherwise the agent can't navigate).
        if p.startswith(rel + "/") or p.startswith(inner + "/"):
            return True
    return False


def is_write_allowed(rel: str, cfg: FenceConfig) -> bool:
    if rel.startswith(_OUTSIDE):
        return False
    inner = _strip_worktree(rel)
    return any(_matches_prefix(rel, p) or _matches_prefix(inner, p)
               for p in cfg.write_allow)


def bash_contains_forbidden(cmd: str, cfg: FenceConfig) -> str | None:
    for blocked in cfg.bash_blocklist:
        if blocked in cmd:
            return blocked
    return None


def validate_read(target: str, cfg: FenceConfig) -> tuple[bool, str | None]:
    """Returns (allowed, reason_if_denied)."""
    rel = rel_to_clone(target, cfg.clone_root)
    if is_read_allowed(rel, cfg):
        return True, None
    return False, (
        f"bench-fence: read of '{target}' is outside the benchmark scope. "
        f"You may only read under: {', '.join(cfg.read_allow)}."
    )


def validate_write(target: str, cfg: FenceConfig) -> tuple[bool, str | None]:
    rel = rel_to_clone(target, cfg.clone_root)
    if is_write_allowed(rel, cfg):
        return True, None
    return False, (
        f"bench-fence: write to '{target}' is outside the benchmark scope. "
        f"You may only write to: {', '.join(cfg.write_allow)}."
    )


def validate_bash(cmd: str, cfg: FenceConfig) -> tuple[bool, str | None]:
    hit = bash_contains_forbidden(cmd, cfg)
    if hit is None:
        return True, None
    return False, (
        f"bench-fence: bash command contains forbidden token '{hit}'. "
        f"The benchmark fences off other cores and history-rewriting git operations; "
        f"restructure your command to operate only on cores/bench/."
    )
