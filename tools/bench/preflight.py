"""Pre-flight checks for the LLM benchmark.

Run this before kicking off the matrix. Catches "discover at hour 4
that XAI_API_KEY was wrong" footguns.

Checks:
  1. pi --version returns something (pi-coding-agent installed)
  2. bench-fence extension typechecks (TypeScript compiles cleanly)
  3. All env vars in models.yaml are set
  4. bench-fixture-v1 ref exists and contains only cores/bench/
  5. Disk has ≥100 GB free
  6. Optional --probe: one zero-cost dry call per model (~$0.10 total)

Usage:
    python -m tools.bench.preflight                     # cheap checks only
    python -m tools.bench.preflight --probe             # + per-model dry calls
    python -m tools.bench.preflight --models models.yaml --ref bench-fixture-v1
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

import yaml


HERE = Path(__file__).parent
DEFAULT_MODELS_YAML = HERE / "models.yaml"
EXTENSION_DIR = HERE / "extensions" / "bench-fence"


def _ok(msg: str) -> None:
    print(f"  ✓  {msg}")


def _fail(msg: str) -> None:
    print(f"  ✗  {msg}", file=sys.stderr)


def check_pi_installed() -> bool:
    print("pi installation:")
    try:
        out = subprocess.run(["pi", "--version"], capture_output=True, text=True, timeout=10)
    except FileNotFoundError:
        _fail("`pi` not on PATH — install with `npm install -g @mariozechner/pi-coding-agent`")
        return False
    except subprocess.TimeoutExpired:
        _fail("`pi --version` timed out after 10s")
        return False
    if out.returncode != 0:
        _fail(f"`pi --version` exited {out.returncode}: {out.stderr.strip()}")
        return False
    _ok(f"pi {out.stdout.strip()}")
    return True


def check_extension() -> bool:
    print("bench-fence extension:")
    if not EXTENSION_DIR.is_dir():
        _fail(f"extension dir missing: {EXTENSION_DIR}")
        return False
    index_ts = EXTENSION_DIR / "index.ts"
    validator_py = HERE / "fence_validator.py"
    if not index_ts.is_file():
        _fail(f"missing {index_ts}")
        return False
    if not validator_py.is_file():
        _fail(f"missing {validator_py}")
        return False
    _ok(f"index.ts in {EXTENSION_DIR}, fence_validator.py in {HERE}")

    # If npm is available, try a typecheck. Skip silently if not — the
    # extension will still be loaded by pi at run time.
    if shutil.which("npm"):
        if (EXTENSION_DIR / "node_modules").is_dir():
            try:
                out = subprocess.run(
                    ["npx", "--no-install", "tsc", "--noEmit", "-p", str(EXTENSION_DIR)],
                    capture_output=True, text=True, timeout=60,
                )
                if out.returncode == 0:
                    _ok("typecheck clean")
                else:
                    _fail(f"typecheck failed: {out.stdout}\n{out.stderr}")
                    return False
            except subprocess.TimeoutExpired:
                _fail("typecheck timed out")
                return False
        else:
            print(f"     (skipped typecheck — run `cd {EXTENSION_DIR} && npm install` to enable)")
    else:
        print("     (skipped typecheck — npm not on PATH)")
    return True


def check_keys(models_yaml: Path) -> bool:
    print("API keys:")
    if not models_yaml.is_file():
        _fail(f"missing {models_yaml}")
        return False
    cfg = yaml.safe_load(models_yaml.read_text())
    needed = sorted({m["key_env"] for m in cfg.get("models", [])})
    missing = [k for k in needed if not os.environ.get(k)]
    if missing:
        _fail(f"unset env vars: {', '.join(missing)}")
        print("     (place them in ~/.bench-keys.env and source before running)")
        return False
    _ok(f"all {len(needed)} key env var(s) set: {', '.join(needed)}")
    return True


def check_fixture(ref: str) -> bool:
    print(f"bench fixture (ref={ref}):")
    out = subprocess.run(
        ["git", "rev-parse", "--verify", ref],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        _fail(f"ref `{ref}` does not exist. Build with: python -m tools.bench.build_fixture")
        return False
    sha = out.stdout.strip()
    _ok(f"{ref} -> {sha[:12]}")

    # Verify cores/bench/ is the only core in the fixture
    out = subprocess.run(
        ["git", "ls-tree", "--name-only", ref, "cores/"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        _fail(f"git ls-tree {ref} cores/ failed: {out.stderr}")
        return False
    cores = [line.strip() for line in out.stdout.strip().splitlines() if line.strip()]
    leaked = [c for c in cores if c != "cores/bench"]
    if leaked:
        _fail(f"fixture leaks other cores: {leaked}")
        return False
    if "cores/bench" not in cores:
        _fail("fixture missing cores/bench/")
        return False
    _ok("only cores/bench/ present in fixture")

    # Verify no docs/ leak
    out = subprocess.run(
        ["git", "ls-tree", "--name-only", ref, "docs/"],
        capture_output=True, text=True,
    )
    if out.stdout.strip():
        _fail(f"fixture leaks docs/: {out.stdout.strip()}")
        return False
    _ok("no docs/ in fixture")
    return True


def check_disk(min_gb: int = 100) -> bool:
    print("disk space:")
    usage = shutil.disk_usage(".")
    free_gb = usage.free / (1024 ** 3)
    if free_gb < min_gb:
        _fail(f"only {free_gb:.1f} GB free, need ≥{min_gb} GB")
        return False
    _ok(f"{free_gb:.1f} GB free")
    return True


def probe_model(name: str, pi_model: str, timeout_sec: int = 30) -> bool:
    """One zero-cost dry call to confirm the model is reachable."""
    cmd = ["pi", "-p", "respond with just OK", "--mode", "json",
           "--model", pi_model, "--tools", ""]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_sec)
    except subprocess.TimeoutExpired:
        _fail(f"{name}: timeout after {timeout_sec}s")
        return False
    if out.returncode != 0:
        snippet = (out.stderr or out.stdout)[:200]
        _fail(f"{name}: rc={out.returncode}  {snippet}")
        return False
    _ok(f"{name}: reachable")
    return True


def check_probes(models_yaml: Path) -> bool:
    print("model probes (dry calls — total cost <$0.10):")
    cfg = yaml.safe_load(models_yaml.read_text())
    ok = True
    for m in cfg.get("models", []):
        if not probe_model(m["name"], m["pi_model"]):
            ok = False
    return ok


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--models", type=Path, default=DEFAULT_MODELS_YAML,
                    help="path to models.yaml (default: tools/bench/models.yaml)")
    ap.add_argument("--ref", default="bench-fixture-v1",
                    help="bench fixture ref (default: bench-fixture-v1)")
    ap.add_argument("--probe", action="store_true",
                    help="also run a dry call per model (costs ~$0.10 total)")
    ap.add_argument("--min-disk-gb", type=int, default=100)
    args = ap.parse_args()

    print("=== bench preflight ===\n")
    checks = [
        check_pi_installed(),
        check_extension(),
        check_keys(args.models),
        check_fixture(args.ref),
        check_disk(args.min_disk_gb),
    ]
    if args.probe:
        checks.append(check_probes(args.models))
    print()
    if all(checks):
        print("preflight: PASS")
        return 0
    print("preflight: FAIL", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
