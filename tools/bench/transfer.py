"""Transfer scorer over rep bundles (E3 Task 5).

For a finished bench rep, clones its final champion tree from
`repo.bundle` (a full-history git bundle captured at rep end by
tools/bench/runner.py), builds that champion's cores/bench simulator,
and runs the held-out kernel eval (tools/eval/holdout.py, E3 Task 3)
against it using the champion's own measured Fmax. Appends one scored
row per invocation to a results file.

Champion clones from repo.bundle deliberately lack bench/holdout: the
E3 guard (tools/bench/runner.py's clone_fixture / the worktree cutter)
bakes its removal into clone history so a hypothesis-implementation
agent can never see the held-out kernels during its own run. The held-
out kernels are core-independent, so this module builds/looks them up
from the repo's own bench/holdout via run_holdout's `holdout_dir`
kwarg (tools/eval/holdout.py) while the champion clone continues to
drive the simulator build (it has the RTL that produced the champion's
Fmax).

CLI:
    python3 -m tools.bench.transfer bench/<model>/rep<N> \\
        [--out research/transfer/results.jsonl]
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from tools.eval import holdout
from tools.eval.holdout import run_holdout

TARGET = "bench"
DEFAULT_OUT = Path("research/transfer/results.jsonl")


class MissingBundleError(RuntimeError):
    """Raised when a rep dir has no repo.bundle (predates bundle capture)."""


class MissingSummaryError(RuntimeError):
    """Raised when a rep dir lacks summary.json. A finalized rep always
    has one (runner.run_one_job writes it, and the orchestrator emits
    run_summary.json even for --iterations 0), so this only fires on a
    truncated/partial rep dir; surfaced as a clean CLI error rather than
    a bare traceback, mirroring MissingBundleError."""


def _repo_root() -> Path:
    # tools/bench/transfer.py -> tools/bench -> tools -> repo root
    return Path(__file__).resolve().parents[2]


def _parse_rep_dir(rep_dir: Path) -> tuple[str, int]:
    """(model, rep) from a bench/<model>/rep<N> path, read off the last
    two path components so absolute or relative paths both work."""
    name = rep_dir.name
    if not name.startswith("rep") or not name[len("rep"):].isdigit():
        raise ValueError(f"expected a rep dir named 'repN', got {name!r}")
    rep = int(name[len("rep"):])
    model = rep_dir.parent.name
    return model, rep


def _champion_fmax_mhz(rep_dir: Path) -> float:
    """The champion's Fmax: the LAST log.jsonl row with
    outcome == 'improvement' (a baseline retest may be the first
    improvement row; the last one is still the final champion, even if
    an earlier improvement happened to have a higher fmax_mhz). Falls
    back to summary.json's best_fmax_mhz, with a warning, only if no
    improvement row exists.
    """
    log_path = rep_dir / "log.jsonl"
    fmax = None
    if log_path.exists():
        with log_path.open() as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                if row.get("outcome") == "improvement" and row.get("fmax_mhz") is not None:
                    fmax = float(row["fmax_mhz"])
    if fmax is not None:
        return fmax

    summary_path = rep_dir / "summary.json"
    if not summary_path.exists():
        raise MissingSummaryError(
            f"{summary_path} not found: rep {rep_dir} has no "
            f"outcome=='improvement' row in log.jsonl and no summary.json "
            f"to fall back to, so the champion Fmax cannot be determined."
        )
    summary = json.loads(summary_path.read_text())
    fallback = float(summary["best_fmax_mhz"])
    print(
        f"WARNING: no outcome=='improvement' row found in {log_path}; "
        f"falling back to summary.json best_fmax_mhz={fallback}",
        file=sys.stderr,
    )
    return fallback


def _coremark_iter_s(rep_dir: Path) -> float:
    """The champion's CoreMark fitness, from summary.json's final_fitness."""
    summary_path = rep_dir / "summary.json"
    if not summary_path.exists():
        raise MissingSummaryError(
            f"{summary_path} not found: rep {rep_dir} has no summary.json, "
            f"so its CoreMark final_fitness cannot be read."
        )
    summary = json.loads(summary_path.read_text())
    return float(summary["final_fitness"])


def _clone_champion(rep_dir: Path, dest: Path) -> None:
    """Clone the rep's final champion tree from repo.bundle into dest
    and check out HEAD. Raises MissingBundleError if the rep has no
    bundle (older reps predate bundle capture)."""
    bundle = rep_dir / "repo.bundle"
    if not bundle.exists():
        raise MissingBundleError(
            f"{bundle} not found: this rep predates repo.bundle capture, "
            f"so its final champion tree cannot be reconstructed for "
            f"transfer scoring."
        )
    subprocess.run(
        ["git", "clone", str(bundle), str(dest)],
        check=True, capture_output=True,
    )
    # Defensive: `git clone` already leaves the bundle's tip checked out,
    # so this is a redundant no-op today. It stays as a guard that the
    # detached tip is materialized on disk before the build step runs, in
    # case a future bundle carries a symbolic-ref HEAD or an unusual
    # default branch. Do not delete it.
    subprocess.run(
        ["git", "checkout", "HEAD"],
        cwd=str(dest), check=True, capture_output=True,
    )


def _build_kernels_once(repo_root: Path) -> None:
    """Build bench/holdout/build/*.elf (if missing) once, eagerly,
    before any champion clone/build work.

    Champion clones lack bench/holdout by E3 design, so every score_rep
    call sources kernel ELFs from repo_root via run_holdout's
    holdout_dir kwarg. Building them here -- before the (multi-minute)
    champion clone+build -- fails fast on a broken kernel build instead
    of surfacing it deep inside the first champion's run_holdout call,
    and avoids a first-build race if a future caller parallelizes
    several score_rep calls that would otherwise all race to build the
    same shared repo_root kernel directory.
    """
    holdout._build_holdout_elfs(repo_root)


def score_rep(rep_dir: Path, repo_root: Path) -> dict:
    """Score one rep's champion against the held-out kernels. Scratch
    clone lives under the caller's TMPDIR and is always removed, even
    on failure; rep_dir itself is only ever read, never mutated."""
    model, rep = _parse_rep_dir(rep_dir)
    fmax_mhz = _champion_fmax_mhz(rep_dir)
    coremark_iter_s = _coremark_iter_s(rep_dir)

    scratch = Path(tempfile.mkdtemp(prefix="e3-transfer-"))
    clone_dir = scratch / "champion"
    try:
        _clone_champion(rep_dir, clone_dir)
        result = run_holdout(
            str(clone_dir), TARGET, fmax_mhz, holdout_dir=str(repo_root),
        )
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    return {
        "model": model,
        "rep": rep,
        "champion_fmax_mhz": fmax_mhz,
        "kernels": result["kernels"],
        "geomean_iter_s": result["geomean_iter_s"],
        "coremark_iter_s": coremark_iter_s,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rep_dir", type=Path,
                         help="bench/<model>/rep<N> directory")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT,
                         help=f"append the scored row here (default: {DEFAULT_OUT})")
    args = parser.parse_args(argv)

    repo_root = _repo_root()
    _build_kernels_once(repo_root)

    try:
        row = score_rep(args.rep_dir, repo_root)
    except MissingBundleError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 3
    except MissingSummaryError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 4

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("a") as f:
        f.write(json.dumps(row) + "\n")

    print(json.dumps(row, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
