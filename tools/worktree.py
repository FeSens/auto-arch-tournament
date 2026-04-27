"""Git worktree lifecycle management."""
import subprocess, shutil
from pathlib import Path

WORKTREE_BASE = Path("experiments/worktrees")

def create_worktree(hypothesis_id: str) -> str:
    """Creates a git worktree at experiments/worktrees/<id>. Returns path.

    Also symlinks the (gitignored) formal/riscv-formal/ tree into the
    worktree so `make formal` works without a fresh ~200 MiB clone per
    iteration.
    """
    WORKTREE_BASE.mkdir(parents=True, exist_ok=True)
    path = str((WORKTREE_BASE / hypothesis_id).resolve())
    subprocess.run(
        ["git", "worktree", "add", "-b", hypothesis_id, path],
        check=True
    )

    main_riscv_formal = Path("formal/riscv-formal").resolve()
    if main_riscv_formal.exists():
        wt_riscv_formal = Path(path) / "formal" / "riscv-formal"
        wt_riscv_formal.parent.mkdir(parents=True, exist_ok=True)
        if not wt_riscv_formal.exists():
            wt_riscv_formal.symlink_to(main_riscv_formal)

    return path

def accept_worktree(hypothesis_id: str, commit_message: str):
    """Merges worktree branch into main and removes the worktree."""
    path = str((WORKTREE_BASE / hypothesis_id).resolve())
    # Commit any uncommitted changes in worktree (SV is the source of truth).
    subprocess.run(["git", "-C", path, "add", "rtl/"], check=True)
    subprocess.run(
        ["git", "-C", path, "commit", "--allow-empty", "-m", commit_message],
        check=True
    )
    # Merge into main
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
