"""Publish HWE Bench whenever a GPT-5.6 rep is finalized locally.

The benchmark runner appends its final row only after copying the rep artifacts
into ``bench/<model>/repN``.  This watcher uses that append as the publication
boundary: rebuild the static site, commit exactly the new rep data plus the
generated HTML, and push ``main`` so the Pages workflow deploys production.

Usage:
    python -m tools.site.watch_publish
    python -m tools.site.watch_publish --once
"""
from __future__ import annotations

import argparse
import json
import subprocess
import time
from pathlib import Path

from tools.site.build import DEFAULT_RESULTS, REPO, SCHEDULED_MODELS


FINAL_STATUSES = {"done", "failed", "timed_out"}
SITE_OUTPUTS = (
    "site/index.html",
    "site/models.html",
    "site/methodology.html",
    "site/data.html",
)
REPORT_OUTPUTS = (
    "bench/LEADERBOARD.md",
    "bench/leaderboard.csv",
)
EXPECTED_REPS = {
    model["name"]: int(model["expected_reps"])
    for model in SCHEDULED_MODELS
}


def _run(*args: str, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=REPO,
        check=True,
        text=True,
        capture_output=capture,
    )


def _rows_from_text(text: str) -> dict[tuple[str, int], dict]:
    rows: dict[tuple[str, int], dict] = {}
    for raw in text.splitlines():
        if not raw.strip():
            continue
        row = json.loads(raw)
        model = row.get("model")
        status = row.get("status")
        if model not in EXPECTED_REPS or status not in FINAL_STATUSES:
            continue
        rows[(model, int(row.get("rep", 0)))] = row
    return rows


def load_current_rows(results_path: Path = DEFAULT_RESULTS) -> dict[tuple[str, int], dict]:
    return _rows_from_text(results_path.read_text())


def load_head_rows() -> dict[tuple[str, int], dict]:
    shown = subprocess.run(
        ["git", "show", "HEAD:bench/results.jsonl"],
        cwd=REPO,
        check=False,
        text=True,
        capture_output=True,
    )
    return _rows_from_text(shown.stdout) if shown.returncode == 0 else {}


def pending_rows(
    current: dict[tuple[str, int], dict],
    committed: dict[tuple[str, int], dict],
) -> list[tuple[str, int]]:
    return sorted(key for key, row in current.items() if committed.get(key) != row)


def field_complete(rows: dict[tuple[str, int], dict]) -> bool:
    return all(
        all((model, rep) in rows for rep in range(1, expected + 1))
        for model, expected in EXPECTED_REPS.items()
    )


def publish_once(results_path: Path = DEFAULT_RESULTS) -> tuple[bool, bool]:
    """Publish pending finalized reps; return (published, field_complete)."""
    current = load_current_rows(results_path)
    pending = pending_rows(current, load_head_rows())
    if not pending:
        return False, field_complete(current)

    # Never fold somebody else's staged work into an automated publication.
    staged = subprocess.run(
        ["git", "diff", "--cached", "--quiet"], cwd=REPO, check=False
    )
    if staged.returncode != 0:
        raise RuntimeError("index contains staged changes; publication deferred")

    rep_paths = []
    for model, rep in pending:
        rel = Path("bench") / model / f"rep{rep}"
        if not (REPO / rel / "summary.json").is_file():
            raise RuntimeError(f"finalized row exists but artifacts are missing: {rel}")
        rep_paths.append(str(rel))

    _run("python", "-m", "tools.bench.report")
    _run("python", "-m", "tools.site.build")
    paths = ["bench/results.jsonl", *rep_paths, *REPORT_OUTPUTS, *SITE_OUTPUTS]
    _run("git", "add", "--", *paths)
    labels = ", ".join(f"{model} rep{rep}" for model, rep in pending)
    _run("git", "commit", "-m", f"bench: publish {labels}", "--", *paths)
    _run("git", "push", "origin", "HEAD:main")
    return True, field_complete(current)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--poll-sec", type=float, default=30.0)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()

    while True:
        try:
            published, complete = publish_once()
            if published:
                print("[site-publish] production push complete", flush=True)
            if complete:
                print("[site-publish] GPT-5.6 field complete", flush=True)
                return 0
        except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
            print(f"[site-publish] deferred: {exc}", flush=True)
        if args.once:
            return 0
        time.sleep(max(args.poll_sec, 5.0))


if __name__ == "__main__":
    raise SystemExit(main())
