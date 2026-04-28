"""Git worktree lifecycle management.

Worktrees are forked off the loop's *active* branch (default: main) and
merged back into that same branch on accept. The active branch is set
by the orchestrator at run start; functions here take it as a parameter
so the same module supports both the default `main` flow and sandbox
research branches without state.
"""
import subprocess, shutil
from pathlib import Path

WORKTREE_BASE = Path("experiments/worktrees")

def create_worktree(hypothesis_id: str, base_branch: str = "main") -> str:
    """Creates a git worktree at experiments/worktrees/<id>. Returns path.

    The new branch <hypothesis_id> is created from <base_branch>'s tip,
    so accepted hypotheses chain on the active branch (whether that is
    main or a sandbox research branch).

    Also symlinks the (gitignored) formal/riscv-formal/ tree into the
    worktree so `make formal` works without a fresh ~200 MiB clone per
    iteration.
    """
    WORKTREE_BASE.mkdir(parents=True, exist_ok=True)
    path = str((WORKTREE_BASE / hypothesis_id).resolve())
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
                    target_branch: str = "main"):
    """Merges worktree branch into target_branch and removes the worktree.

    Caller is responsible for ensuring target_branch is the active branch
    of the orchestrator's run. We `git checkout target_branch` first
    (idempotent if already on it), then ff-merge the worktree branch.
    """
    path = str((WORKTREE_BASE / hypothesis_id).resolve())
    # Commit any uncommitted changes in worktree. Stage exactly the
    # paths the agent is permitted to modify (rtl/ + test/test_*.py).
    # The orchestrator's sandbox check runs BEFORE this is reached, so
    # in practice these are the only dirty paths anyway. -A picks up
    # adds, modifies, and deletes inside each prefix.
    subprocess.run(["git", "-C", path, "add", "-A", "rtl/"], check=True)
    test_changes = subprocess.run(
        ["git", "-C", path, "ls-files", "--modified", "--others", "--exclude-standard",
         "test/test_*.py"],
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
    destroy_worktree(hypothesis_id)

def destroy_worktree(hypothesis_id: str):
    """Removes worktree and deletes the branch."""
    path = str((WORKTREE_BASE / hypothesis_id).resolve())
    subprocess.run(["git", "worktree", "remove", "--force", path], check=False)
    subprocess.run(["git", "branch", "-D", hypothesis_id], check=False)
    shutil.rmtree(path, ignore_errors=True)
