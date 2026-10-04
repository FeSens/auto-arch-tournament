#!/usr/bin/env python3
"""Export every V2 run's scribe lessons for the paper.

For each rep dir under bench/v2 (and bench/v2/smoke-*), writes
<rep>/LESSONS.md: the run's final cores/bench/LESSONS.md, read from
repo.bundle. A run without a bundle (the first runs, whose clones predate
bundling) gets it rebuilt from log.jsonl's `lesson` fields, which hold each
bullet the scribe appended. Where both exist they are compared: the bundle
can hold a bullet the log lacks when the scribe wrote it and then exited
non-zero (the log then says scribe_skipped), so the bundle is authoritative
and a rebuilt file can miss such bullets (their count is reported). Also
writes research/v2/lessons/all_lessons.jsonl, one row per lesson: model,
rep, hypothesis id, outcome, delta_pct, lesson.

The same pass scans each bundle's full history (every commit's patch) for
credential patterns and prints counts only; strings that already occur in
the repository's tracked files (a unit test's dummy token) are not counted.

    python3 -B research/v2/scripts/export_lessons.py
"""
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path("/home/bench/auto-arch-tournament")
V2 = REPO / "bench/v2"
OUT = REPO / "research/v2/lessons"
SECRET = re.compile(rb"sk-ant-[A-Za-z0-9_-]{10,}|sk-(proj-)?[A-Za-z0-9]{20,}|[Bb]earer [A-Za-z0-9._-]{20,}")


def known_strings() -> set[bytes]:
    out = subprocess.run(["git", "-C", str(REPO), "grep", "-ohIE", SECRET.pattern.decode()],
                         capture_output=True).stdout
    return set(out.split())


def log_lessons(log: Path) -> tuple[list[str], list[dict], int]:
    lines, rows, skipped = [], [], 0
    for l in log.read_text().splitlines():
        if not l.strip():
            continue
        e = json.loads(l)
        skipped += bool(e.get("scribe_skipped"))
        if e.get("lesson"):
            bullets = [x for x in e["lesson"].splitlines() if x.strip()]
            lines += bullets
            rows += [{"id": e.get("id"), "outcome": e.get("outcome"),
                      "delta_pct": e.get("delta_pct"), "lesson": b} for b in bullets]
    return lines, rows, skipped


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    reps = sorted(p for p in list(V2.glob("*/rep*")) + list(V2.glob("smoke-*/*/rep*")) if p.is_dir())
    all_rows, bad, notes = [], [], []
    known = known_strings()
    for rep in reps:
        log = rep / "log.jsonl"
        if not log.exists():
            continue
        lines, rows, skipped = log_lessons(log)
        model = rep.parent.name
        smoke = rep.parent.parent.name if rep.parent.parent != V2 else None
        source, hits = "log.jsonl", None
        bundle = rep / "repo.bundle"
        if bundle.exists():
            with tempfile.TemporaryDirectory(dir="/tmp/claude-1000") as t:
                subprocess.run(["git", "clone", "-q", str(bundle), f"{t}/r"], check=True,
                               capture_output=True)
                md = Path(t) / "r/cores/bench/LESSONS.md"
                final = md.read_text() if md.exists() else ""
                patch = subprocess.run(["git", "-C", f"{t}/r", "log", "-p", "--all"],
                                       capture_output=True).stdout
                hits = sum(m.group(0) not in known for m in SECRET.finditer(patch))
            md_lines = [l for l in final.splitlines() if l.strip()]
            if md_lines != lines:
                extra = [l for l in md_lines if l not in lines]
                missing = [l for l in lines if l not in md_lines]
                msg = (f"{rep.relative_to(V2)}: bundle has {len(extra)} bullet(s) the log lacks, "
                       f"log has {len(missing)} the bundle lacks; log scribe_skipped entries: {skipped}")
                (bad if missing else notes).append(msg)
            (rep / "LESSONS.md").write_text(final)
            source = "repo.bundle"
        else:
            (rep / "LESSONS.md").write_text("".join(l + "\n" for l in lines))
            if skipped:
                notes.append(f"{rep.relative_to(V2)}: rebuilt from log.jsonl; {skipped} scribe_skipped "
                             f"entries may each have written a bullet the log lacks")
        for r in rows:
            all_rows.append({"model": model, "rep": int(rep.name[3:]), "smoke": smoke, **r})
        print(f"{rep.relative_to(V2)}: {len(lines)} lessons from {source}"
              + (f", bundle history secret hits {hits}" if hits is not None else ""))
        if hits:
            bad.append(f"{rep}: {hits} secret-pattern hits in bundle history")
    (OUT / "all_lessons.jsonl").write_text("".join(json.dumps(r) + "\n" for r in all_rows))
    print(f"{len(all_rows)} lessons -> {OUT / 'all_lessons.jsonl'}")
    for n in notes:
        print("NOTE:", n)
    for b in bad:
        print("PROBLEM:", b)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
