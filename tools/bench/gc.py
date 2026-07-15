"""Sweep stale bench-run clones and formal work dirs.

Usage:
    python -m tools.bench.gc            # dry-run: list + sizes
    python -m tools.bench.gc --delete   # actually remove

Two garbage sources, per the task-7 disk-hygiene audit (2026-07-15):

1. `.claude/bench-runs/<model>-rep<N>/` -- per-job standalone clones
   (each carries its own `formal/riscv-formal` copy, worktrees,
   generated/ artifacts). Once a (model, rep) has a finalized rep dir
   under `bench/<model>/rep<N>/`, the clone is redundant: everything
   that matters (log.jsonl, agent.log, summary.json) was already copied
   out by run_one_job's finalize. This sweeper additionally backfills
   two forensics files older clones may predate --
   `.tmp/orchestrator.log` and `.tmp/env.json` -- into the rep dir if
   still absent, and creates `repo.bundle` (full git history: accepted
   diffs, log commits) there if absent, before removing the clone.
   `bench/` itself is an append-only record and is never touched here;
   only the redundant `.claude/bench-runs/` clone is removed.

2. `formal/riscv-formal/cores/*-[0-9]*` in the MAIN repo checkout --
   the same per-PID SBY work-dir garbage that formal.py's
   `_cleanup_formal_workdir` now reaps automatically after every
   `run_formal()` call (tools/eval/formal.py), but only for runs that
   actually complete through that path. Manual `bash formal/run_all.sh`
   invocations, interrupted runs, or historical residue predating that
   cleanup still accumulate here; this sweeper is the periodic backstop.
   Tracked upstream reference cores (nerv, picorv32, serv, VexRiscv) are
   never matched by the PID-suffix glob and are never touched.
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).parent
REPO_ROOT = HERE.parent.parent
DEFAULT_CLONE_BASE = REPO_ROOT / ".claude" / "bench-runs"
DEFAULT_RESULTS_DIR = REPO_ROOT / "bench"
DEFAULT_RISCV_FORMAL_CORES = REPO_ROOT / "formal" / "riscv-formal" / "cores"

# Matches JobSpec.slug in tools/bench/runner.py: f"{model.name}-rep{rep}".
# Model names may themselves contain dashes (e.g. "gpt-5_6-sol"), so the
# match is anchored on the trailing "-rep<digits>" rather than splitting
# on the first dash.
_SLUG_RE = re.compile(r"^(?P<model>.+)-rep(?P<rep>\d+)$")

# Same discriminator as formal/run_all.sh's own stale-work-dir reaper:
# a directory name ending in "-<digits>" is a PID-suffixed SBY work dir.
_PID_SUFFIXED = re.compile(r"^.+-\d+$")


def parse_slug(slug: str) -> tuple[str, int] | None:
    """Parse a `.claude/bench-runs/<slug>` directory name into
    (model_name, rep). Returns None if it doesn't match the
    `<model>-rep<N>` convention."""
    m = _SLUG_RE.match(slug)
    if not m:
        return None
    return m.group("model"), int(m.group("rep"))


def _du_bytes(path: Path) -> int:
    """Total size of path (file or directory tree), best-effort."""
    if path.is_file():
        return path.stat().st_size
    total = 0
    for p in path.rglob("*"):
        try:
            if p.is_file() and not p.is_symlink():
                total += p.stat().st_size
        except (FileNotFoundError, PermissionError):
            continue
    return total


def _fmt_bytes(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}PB"


def find_stale_clones(clone_base: Path, results_dir: Path) -> list[Path]:
    """`.claude/bench-runs/<slug>` clones whose (model, rep) already has
    a finalized rep dir under `bench/<model>/rep<N>/`."""
    if not clone_base.is_dir():
        return []
    stale = []
    for d in sorted(clone_base.iterdir()):
        if not d.is_dir():
            continue
        parsed = parse_slug(d.name)
        if parsed is None:
            continue
        model, rep = parsed
        rep_dir = results_dir / model / f"rep{rep}"
        if rep_dir.is_dir():
            stale.append(d)
    return stale


def find_stale_formal_workdirs(riscv_formal_cores: Path) -> list[Path]:
    """PID-suffixed SBY work dirs directly under the main repo's
    formal/riscv-formal/cores/. Tracked upstream reference cores never
    match (no numeric suffix)."""
    if not riscv_formal_cores.is_dir():
        return []
    return sorted(
        p for p in riscv_formal_cores.iterdir()
        if p.is_dir() and _PID_SUFFIXED.match(p.name)
    )


def archive_clone_forensics(clone: Path, rep_dir: Path) -> list[str]:
    """Backfill `.tmp/orchestrator.log` + `.tmp/env.json` from the clone
    into rep_dir (only if not already present there), and create
    rep_dir/repo.bundle (full git history) if absent. Never overwrites
    an existing file in rep_dir. Returns a list of human-readable
    actions taken, for the dry-run / --delete log."""
    actions: list[str] = []
    tmp = clone / ".tmp"
    for name in ("orchestrator.log", "env.json"):
        src = tmp / name
        dest = rep_dir / name
        if src.is_file() and not dest.exists():
            rep_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)
            actions.append(f"archived {name}")

    bundle_dest = rep_dir / "repo.bundle"
    if not bundle_dest.exists() and (clone / ".git").exists():
        rep_dir.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            ["git", "bundle", "create", str(bundle_dest), "--all"],
            cwd=str(clone), capture_output=True)
        if result.returncode == 0:
            actions.append("created repo.bundle")
        else:
            actions.append(
                f"WARN: git bundle failed: {result.stderr.decode()[:200]}")
    return actions


def verify_forensics(rep_dir: Path) -> bool:
    """True iff rep_dir has both orchestrator.log and repo.bundle --
    the two artifacts the CLAUDE.md safety rule requires to exist before
    a clone backing them is deleted."""
    return (rep_dir / "orchestrator.log").is_file() and \
           (rep_dir / "repo.bundle").is_file()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--delete", action="store_true",
                    help="actually remove targets (default: dry-run, list only)")
    ap.add_argument("--clone-base", type=Path, default=DEFAULT_CLONE_BASE)
    ap.add_argument("--results-dir", type=Path, default=DEFAULT_RESULTS_DIR)
    ap.add_argument("--riscv-formal-cores", type=Path,
                    default=DEFAULT_RISCV_FORMAL_CORES)
    args = ap.parse_args(argv)

    clones = find_stale_clones(args.clone_base, args.results_dir)
    workdirs = find_stale_formal_workdirs(args.riscv_formal_cores)

    total_reclaimed = 0
    total_reclaimable = 0

    print("[gc] stale bench-run clones "
          f"(finalized rep dir already exists under {args.results_dir}):")
    if not clones:
        print("  (none)")
    for clone in clones:
        model, rep = parse_slug(clone.name)
        rep_dir = args.results_dir / model / f"rep{rep}"
        size = _du_bytes(clone)
        total_reclaimable += size
        print(f"  {clone}  ({_fmt_bytes(size)})")
        if not args.delete:
            continue
        for action in archive_clone_forensics(clone, rep_dir):
            print(f"    {action}")
        if not verify_forensics(rep_dir):
            print(f"    SKIP: forensics incomplete in {rep_dir} "
                  f"(need orchestrator.log + repo.bundle) -- clone kept")
            continue
        shutil.rmtree(clone, ignore_errors=True)
        total_reclaimed += size
        print(f"    removed ({_fmt_bytes(size)})")

    print("\n[gc] stale formal work dirs "
          f"(main repo {args.riscv_formal_cores}):")
    if not workdirs:
        print("  (none)")
    for workdir in workdirs:
        size = _du_bytes(workdir)
        total_reclaimable += size
        print(f"  {workdir}  ({_fmt_bytes(size)})")
        if not args.delete:
            continue
        shutil.rmtree(workdir, ignore_errors=True)
        total_reclaimed += size
        print(f"    removed ({_fmt_bytes(size)})")

    if args.delete:
        print(f"\n[gc] total reclaimed: {_fmt_bytes(total_reclaimed)}")
    else:
        print(f"\n[gc] total reclaimable: {_fmt_bytes(total_reclaimable)} "
              f"(dry-run; pass --delete to remove)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
