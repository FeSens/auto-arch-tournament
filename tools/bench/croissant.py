"""Generate bench-fixture-v1.croissant.json — Croissant JSON-LD manifest."""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def file_sha256_from_ref(repo_root: Path, ref: str, path: str) -> str:
    """Read file contents from a git ref (without checkout) and hash."""
    out = subprocess.run(
        ["git", "show", f"{ref}:{path}"],
        cwd=repo_root, capture_output=True, check=False,
    )
    if out.returncode != 0:
        return ""
    h = hashlib.sha256()
    h.update(out.stdout)
    return h.hexdigest()


def list_ref_files(repo_root: Path, ref: str) -> list[str]:
    out = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", ref],
        cwd=repo_root, capture_output=True, text=True, check=True,
    )
    return [line.strip() for line in out.stdout.splitlines() if line.strip()]


def build(ref: str, repo_root: Path, repo_url_template: str) -> dict:
    sha = subprocess.run(
        ["git", "rev-parse", ref],
        cwd=repo_root, capture_output=True, text=True, check=True,
    ).stdout.strip()
    files = list_ref_files(repo_root, ref)
    manifest = []
    for rel in files:
        manifest.append({
            "@type": "cr:FileObject",
            "@id": rel,
            "name": rel,
            "contentUrl": repo_url_template.format(sha=sha, path=rel),
            "sha256": file_sha256_from_ref(repo_root, ref, rel),
        })
    return {
        "@context": {
            "@vocab": "https://schema.org/",
            "cr": "http://mlcommons.org/croissant/",
        },
        "@type": "sc:Dataset",
        "name": "bench-fixture-v1",
        "description": (
            "Out-of-distribution code-generation benchmark for LLM coding "
            "agents on RV32IM SystemVerilog RTL design, gated by riscv-formal "
            "symbolic BMC, Verilator cosim, and 3-seed yosys/nextpnr-himbaechel "
            "place-and-route on Gowin GW2AR-LV18."
        ),
        "license": "Apache-2.0",
        "url": f"https://github.com/<OWNER>/auto-arch-tournament/tree/{ref}",
        "version": "1.0.0",
        "datePublished": "[ZENODO_DOI_DATE]",
        "creator": [{"@type": "Person", "name": "Anonymous"}],
        "distribution": manifest,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default="bench-fixture-v1")
    ap.add_argument("--out", default="bench-fixture-v1.croissant.json")
    ap.add_argument("--repo-root", default=".")
    ap.add_argument(
        "--repo-url-template",
        default="https://github.com/<OWNER>/auto-arch-tournament/raw/{sha}/{path}",
        help="URL template; {sha} and {path} are substituted",
    )
    args = ap.parse_args()
    obj = build(args.ref, Path(args.repo_root), args.repo_url_template)
    Path(args.out).write_text(json.dumps(obj, indent=2))


if __name__ == "__main__":
    main()
