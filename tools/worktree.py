"""Git worktree lifecycle management.

Worktrees are forked off the loop's *active* branch (default: main) and
merged back into that same branch on accept. The active branch is set
by the orchestrator at run start; functions here take it as a parameter
so the same module supports both the default `main` flow and sandbox
research branches without state.
"""
import subprocess, shutil
from pathlib import Path


def _worktree_base(target: str | None) -> Path:
    """Returns the base directory for worktrees.

    Args:
        target -- core target name (e.g. "rv32i"), or None for the default
                  single-core layout (experiments/worktrees/).
    """
    if target is None:
        return Path("experiments/worktrees")
    return Path("cores") / target / "worktrees"


def _branch_name(hypothesis_id: str, target: str | None) -> str:
    """Returns the git branch name for a hypothesis run.

    Git refs are shared across all worktrees in a repo, so two parallel
    `make loop TARGET=mini` and `make loop TARGET=maxperf` runs that each
    allocate `hyp-20260429-001-r1s0` (independently — _next_id counts files
    per-target) would collide on the branch ref. Prefixing the branch with
    the target keeps the namespaces separate.

    The hypothesis_id itself (used as YAML filename, log entry id, and
    worktree dir name) is left unchanged — it's the human-facing identifier
    and doesn't need the prefix because the YAML/log paths are already
    per-target.
    """
    if target is None:
        return hypothesis_id
    return f"{target}-{hypothesis_id}"


def create_worktree(hypothesis_id: str, base_branch: str = "main",
                    target: str | None = None) -> str:
    """Creates a git worktree for hypothesis_id. Returns path.

    The new branch <hypothesis_id> is created from <base_branch>'s tip,
    so accepted hypotheses chain on the active branch (whether that is
    main or a sandbox research branch).

    Also symlinks the (gitignored) formal/riscv-formal/ tree into the
    worktree so `make formal` works without a fresh ~200 MiB clone per
    iteration.

    Args:
        hypothesis_id -- unique identifier for this hypothesis run.
        base_branch   -- git branch to fork from (default: "main").
        target        -- core target name, or None for the default layout
                         (worktree under experiments/worktrees/).
    """
    base = _worktree_base(target)
    base.mkdir(parents=True, exist_ok=True)
    path = str((base / hypothesis_id).resolve())
    branch = _branch_name(hypothesis_id, target)
    # Defensive: a prior crashed iteration may have left the branch ref
    # behind (worktree removed but `git branch -D` never ran). git refs
    # are shared across all worktrees of the same repo, so the stale ref
    # would block `git worktree add -b`. Nuke it first if present —
    # hypothesis branches are per-iteration ephemeral anyway.
    subprocess.run(
        ["git", "worktree", "prune"],
        check=False, capture_output=True,
    )
    subprocess.run(
        ["git", "branch", "-D", branch],
        check=False, capture_output=True,
    )
    subprocess.run(
        ["git", "worktree", "add", "-b", branch, path, base_branch],
        check=True
    )

    # Assume-unchanged any tracked .pyc / __pycache__ paths in the
    # sub-worktree's index. Some fixture branches accidentally
    # committed bytecode (legacy bench-fixture-v1 carries
    # tools/__pycache__/__init__.cpython-313.pyc, etc.). When Python
    # imports modules from the worktree (e.g. the static-control
    # agent invokes `python -m tools.agents.static_agent`), it
    # rewrites the pyc, and `git status --porcelain` flags every
    # tracked pyc as M — which the orchestrator's sandbox check
    # then reports as `sandbox_violation: agent touched off-limits
    # paths`. clone_fixture does the same assume-unchanged on the
    # rep clone's index; per-worktree indices don't inherit it,
    # so we re-apply here.
    tracked = subprocess.run(
        ["git", "-C", path, "ls-files"],
        capture_output=True, text=True,
    ).stdout.splitlines()
    pyc_paths = [p for p in tracked if p.endswith(".pyc") or "/__pycache__/" in p]
    if pyc_paths:
        subprocess.run(
            ["git", "-C", path, "update-index", "--assume-unchanged", *pyc_paths],
            capture_output=True,
        )

    main_riscv_formal = Path("formal/riscv-formal").resolve()
    if main_riscv_formal.exists():
        wt_riscv_formal = Path(path) / "formal" / "riscv-formal"
        wt_riscv_formal.parent.mkdir(parents=True, exist_ok=True)
        if not wt_riscv_formal.exists():
            wt_riscv_formal.symlink_to(main_riscv_formal)

    return path

def accept_worktree(hypothesis_id: str,
                    commit_message: str,
                    target_branch: str = "main",
                    target: str | None = None):
    """Merges worktree branch into target_branch and removes the worktree.

    Caller is responsible for ensuring target_branch is the active branch
    of the orchestrator's run. We `git checkout target_branch` first
    (idempotent if already on it), then ff-merge the worktree branch.

    Args:
        hypothesis_id  -- unique identifier for this hypothesis run.
        commit_message -- commit message to use when committing worktree changes.
        target_branch  -- git branch to merge into (default: "main").
        target         -- core target name, or None for the default layout
                          (stages rtl/ and test/test_*.py).
    """
    path = str((_worktree_base(target) / hypothesis_id).resolve())
    # Commit any uncommitted changes in worktree. Stage exactly the
    # paths the agent is permitted to modify. For a named target the scope
    # is cores/<target>/; for the default layout it is rtl/ + test/test_*.py.
    # The orchestrator's sandbox check runs BEFORE this is reached, so
    # in practice these are the only dirty paths anyway. -A picks up
    # adds, modifies, and deletes inside each prefix.
    add_path = f"cores/{target}/" if target else "rtl/"
    subprocess.run(["git", "-C", path, "add", "-A", add_path], check=True)
    test_glob = f"cores/{target}/test/test_*.py" if target else "test/test_*.py"
    test_changes = subprocess.run(
        ["git", "-C", path, "ls-files", "--modified", "--others", "--exclude-standard",
         test_glob],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    if test_changes:
        subprocess.run(["git", "-C", path, "add", "--"] + test_changes, check=True)
    subprocess.run(
        ["git", "-C", path, "commit", "--allow-empty", "-m", commit_message],
        check=True
    )

    # Merge into the active branch. Idempotent checkout — no-op if already on it.
    subprocess.run(["git", "checkout", target_branch], check=True)
    subprocess.run(
        ["git", "merge", "--ff-only", _branch_name(hypothesis_id, target)],
        check=True
    )
    destroy_worktree(hypothesis_id, target=target)

def destroy_worktree(hypothesis_id: str, target: str | None = None):
    """Removes worktree and deletes the branch.

    Args:
        hypothesis_id -- unique identifier for this hypothesis run.
        target        -- core target name, or None for the default layout.
    """
    path = str((_worktree_base(target) / hypothesis_id).resolve())
    subprocess.run(["git", "worktree", "remove", "--force", path], check=False)
    subprocess.run(["git", "branch", "-D", _branch_name(hypothesis_id, target)], check=False)
    shutil.rmtree(path, ignore_errors=True)
