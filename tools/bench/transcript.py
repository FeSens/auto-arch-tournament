"""Compact agent transcripts before they are committed under bench/.

Measured on the published reps (2026-09): ~77% of agent.log bytes are
tool OUTPUT echoed back into the transcript (a single `rg` over the repo
can print 1 MB), plus opaque encrypted reasoning blobs. Committing that
verbatim grows the git history by megabytes per rep, forever.

compact_transcript() keeps every line and every JSON field verbatim
EXCEPT the tool-output / opaque-blob fields listed in _CAPPED_PATHS, which
are cut to a head + tail around an elision marker recording the original
length and sha256. Everything the model authored (messages, commands,
patches, reasoning text) and all usage/cost events are untouched, so the
cost parsers produce the same numbers on the compacted file.

The uncompacted transcript is kept next to it as agent.full.log.gz
(gitignored), like repo.bundle: local forensics, not published data.
"""
from __future__ import annotations

import gzip
import hashlib
import json
import shutil
from pathlib import Path

# Strings longer than this in a capped field are elided.
FIELD_CAP = 4096
_HEAD = 2048
_TAIL = 1024

# JSON key paths (list indices written as "[]") holding tool output or
# opaque data, per runtime:
#   codex:            item.aggregated_output
#   opencode / pi:    part.state.output, part.state.metadata.{output,preview}
#   openrouter:       part.metadata.openrouter.reasoning_details[].data
#                     (encrypted reasoning; the readable .text is kept)
_CAPPED_PATHS = frozenset({
    ("item", "aggregated_output"),
    ("part", "state", "output"),
    ("part", "state", "metadata", "output"),
    ("part", "state", "metadata", "preview"),
    ("part", "metadata", "openrouter", "reasoning_details", "[]", "data"),
})


def _elide(s: str) -> str:
    digest = hashlib.sha256(s.encode("utf-8", "surrogatepass")).hexdigest()[:16]
    return (f"{s[:_HEAD]}\n…[{len(s) - _HEAD - _TAIL} of {len(s)} chars elided "
            f"by tools/bench/transcript.py; sha256:{digest}]…\n{s[-_TAIL:]}")


def _compact(obj, path: tuple = ()):
    if isinstance(obj, dict):
        return {k: _compact(v, path + (k,)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_compact(v, path + ("[]",)) for v in obj]
    if isinstance(obj, str) and len(obj) > FIELD_CAP and path in _CAPPED_PATHS:
        return _elide(obj)
    return obj


def compact_line(line: str) -> str:
    """One transcript line, compacted. Non-JSON lines pass through."""
    body = line.rstrip("\n")
    if len(body) <= FIELD_CAP or not body.startswith("{"):
        return line
    try:
        obj = json.loads(body)
    except ValueError:
        return line
    out = json.dumps(_compact(obj), ensure_ascii=False)
    return out + ("\n" if line.endswith("\n") else "")


def compact_transcript(src: Path, dst: Path) -> None:
    with open(src, encoding="utf-8", errors="surrogateescape") as fin, \
         open(dst, "w", encoding="utf-8", errors="surrogateescape") as fout:
        for line in fin:
            fout.write(compact_line(line))


def publish_transcript(src: Path, out_dir: Path) -> None:
    """Write out_dir/agent.log (compacted, tracked) and
    out_dir/agent.full.log.gz (verbatim, gitignored) from src."""
    compact_transcript(src, out_dir / "agent.log")
    with open(src, "rb") as fin, gzip.open(out_dir / "agent.full.log.gz", "wb") as fout:
        shutil.copyfileobj(fin, fout)
