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
        ["git", "branch", "-D", hypothesis_id],
        check=False, capture_output=True,
    )
    subprocess.run(
        ["git", "worktree", "add", "-b", hypothesis_id, path, base_branch],
        check=True
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
        ["git", "merge", "--ff-only", hypothesis_id],
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
    subprocess.run(["git", "branch", "-D", hypothesis_id], check=False)
    shutil.rmtree(path, ignore_errors=True)
