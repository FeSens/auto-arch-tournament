"""Build the `bench-fixture-v1` orphan branch.

One-time setup: from `main`, construct a single-commit orphan branch
containing only the benchmark surface (cores/bench/ + shared infra).
The benchmark matrix clones from this ref.

Idempotent: re-running rebuilds the orphan branch from current main
state, deleting and recreating the ref. Use this when bumping the
fixture (e.g., after pulling an upstream improvement into shared infra
that the benchmark should pick up).

Usage:
    python -m tools.bench.build_fixture [--ref bench-fixture-v1] [--dry-run]
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


# Paths the fixture KEEPS (everything else is removed before commit).
# These are read off `main` at commit time; if they don't exist on main,
# they're skipped silently.
KEEP_PATHS = [
    "cores/bench",
    "formal",
    "fpga",
    "bench/programs",
    "test/cosim",
    "tools",
    "schemas",
    "Makefile",
    "ARCHITECTURE.md",
    "CLAUDE.md",
    "README.md",
    "setup.sh",
    ".gitignore",
]

# Paths the fixture REMOVES even if they're under a kept path.
# experiments/ inside cores/bench/ would leak prior results across reps.
REMOVE_PATHS = [
    "cores/bench/experiments",
]


def run(cmd: list[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess:
    if capture:
        return subprocess.run(cmd, check=check, capture_output=True, text=True)
    return subprocess.run(cmd, check=check)


def is_clean() -> bool:
    out = run(["git", "status", "--porcelain"], capture=True)
    return out.stdout.strip() == ""


def current_branch() -> str:
    out = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], capture=True)
    return out.stdout.strip()


def list_other_cores() -> list[str]:
    """Return cores/<name>/ paths that are NOT cores/bench/."""
    cores_dir = Path("cores")
    if not cores_dir.is_dir():
        return []
    return sorted(
        str(p) for p in cores_dir.iterdir()
        if p.is_dir() and p.name != "bench"
    )


def build_fixture(ref: str = "bench-fixture-v1", dry_run: bool = False,
                  allow_any_branch: bool = False) -> int:
    if not Path(".git").exists():
        print("error: not in a git repo root", file=sys.stderr)
        return 1
    starting_branch = current_branch()
    if not allow_any_branch and starting_branch != "main":
        print(f"error: must run from `main`, currently on `{starting_branch}`. "
              f"Pass --any-branch to override.", file=sys.stderr)
        return 1
    if not is_clean():
        print("error: working tree must be clean (commit or stash first)",
              file=sys.stderr)
        return 1
    if not Path("cores/bench").is_dir():
        print("error: cores/bench/ does not exist on main. "
              "Fork it from cores/baseline/ first (cp -r cores/baseline cores/bench).",
              file=sys.stderr)
        return 1

    # Paths the fixture must remove (other cores + design docs).
    # NOT removing top-level `bench/` wholesale — bench/programs/ is in
    # the keep list (selftest, crt0, link.ld, CoreMark sources). We
    # nuke specific bench/ subpaths instead.
    other_cores = list_other_cores()
    bench_to_remove = []
    bench_dir = Path("bench")
    if bench_dir.is_dir():
        for child in bench_dir.iterdir():
            if child.name == "programs":
                continue
            bench_to_remove.append(str(child))
    paths_to_remove = other_cores + bench_to_remove + [
        "docs",
        ".claude",
        ".worktrees",
        "experiments",
    ] + REMOVE_PATHS

    print(f"[fixture] starting build of orphan branch `{ref}`")
    print(f"[fixture] keeping: {', '.join(KEEP_PATHS)}")
    print(f"[fixture] removing: {', '.join(paths_to_remove)}")

    if dry_run:
        print("[fixture] dry-run — no changes made")
        return 0

    try:
        # 1. Delete the existing ref if any (clean rebuild).
        run(["git", "branch", "-D", ref], check=False, capture=True)
        run(["git", "tag", "-d", ref], check=False, capture=True)

        # 2. Create orphan branch (no parent commits, working tree preserved).
        run(["git", "checkout", "--orphan", ref])

        # 3. Reset the staging area; we'll add the keep-list back explicitly.
        run(["git", "rm", "-rf", "--cached", "."], check=False, capture=True)

        # 4. Remove untracked paths the fixture must not include.
        for p in paths_to_remove:
            target = Path(p)
            if target.is_dir():
                shutil.rmtree(target, ignore_errors=True)
            elif target.exists():
                target.unlink(missing_ok=True)

        # 5. Add only the keep-list back.
        for p in KEEP_PATHS:
            if Path(p).exists():
                run(["git", "add", "--force", p])

        # 6. Commit.
        run(["git", "-c", "user.email=bench-fixture@local",
             "-c", "user.name=bench-fixture",
             "commit", "-m", f"{ref}: frozen LLM-benchmark fixture"])

        # 7. Tag for stable reference.
        run(["git", "tag", ref])

        # 8. Return to main (the orphan ref still exists for cloning).
        run(["git", "checkout", starting_branch])

        # 9. Restore the files we removed in step 4 (they live on main, the
        #    checkout in step 8 should bring them back, but anything under
        #    .gitignore won't — leave that to the user).
        print(f"[fixture] OK: `{ref}` built and tagged. "
              f"Returned to `{starting_branch}`.")
        print(f"[fixture] verify:  git log {ref} --oneline      "
              f"(should show one commit)")
        print(f"[fixture] clone:   git clone --depth 1 --branch {ref} "
              f"--single-branch <repo> <dest>")
        return 0
    except subprocess.CalledProcessError as e:
        print(f"error: {e}", file=sys.stderr)
        # Try to recover
        run(["git", "checkout", starting_branch], check=False)
        return 2


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ref", default="bench-fixture-v1",
                    help="orphan branch + tag name (default: bench-fixture-v1)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print what would happen without making changes")
    ap.add_argument("--any-branch", action="store_true",
                    help="allow building from a non-main branch (worktrees, dev branches)")
    args = ap.parse_args()
    return build_fixture(ref=args.ref, dry_run=args.dry_run,
                         allow_any_branch=args.any_branch)


if __name__ == "__main__":
    raise SystemExit(main())
