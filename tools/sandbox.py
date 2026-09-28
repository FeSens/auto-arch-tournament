"""Contract-integrity checks that complement the per-worktree git-status sandbox.

`orchestrator.offlimits_changes` runs `git status --porcelain` inside the
slot's worktree. That catches tracked and untracked-not-ignored edits in
the worktree, but it is blind to three routes an implementation agent
(running with `--dangerously-skip-permissions`, i.e. as the user) has for
influencing its own score:

  1. Gitignored files inside the worktree. `git status` never lists them,
     yet the eval consumes several: `make` keeps a planted
     `bench/programs/coremark.elf` whose mtime is newer than its sources,
     and `formal/run_all.sh` prepends `<worktree>/.toolchain/oss-cad-suite/bin`
     to PATH, so a fake `sby` dropped there would "pass" every check.
     -> `purge_ignored_outputs` deletes every ignored path in the worktree
        (except a short keep-list) before the build step, so the eval only
        ever consumes artifacts it built itself.

  2. Files outside the worktree. The agent's bash tool commonly runs with
     the orchestrator's cwd (the main checkout), and `formal/riscv-formal`
     in every worktree is a symlink into a checkout shared by all slots.
     Edits there never show up in the worktree's `git status`.
     -> `take_snapshot` / `snapshot_changes` fingerprint the main
        checkout's contract paths, the shared riscv-formal checkout, and
        the resolved EDA toolchain binaries before the agent runs, and
        report anything that changed afterwards.

  3. Anything else on the machine (shell rc files, site-packages, compiler
     runtime libraries). Not covered here: closing that needs OS-level
     isolation of the agent process (container / sandbox-exec), not a
     post-hoc check. See ARCHITECTURE.md "Sandbox".

Every check here fails closed: a concurrent slot's agent tampering during
this slot's window flags this slot too. Attribution is ambiguous in that
case, but a contract breach must never reach an accepted result.
"""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
from pathlib import Path

# Paths whose content defines the eval contract (CLAUDE.md "Don't-touch
# list"), relative to a checkout root. Missing paths are skipped, so
# fixture clones that strip e.g. bench/holdout are fine.
CONTRACT_PATHS = (
    "tools",
    "schemas",
    "formal/wrapper.sv",
    "formal/wrapper_si.sv",
    "formal/checks.cfg",
    "formal/checks_si.cfg",
    "formal/checks-deep.cfg",
    "formal/run_all.sh",
    "bench/programs",
    "bench/holdout",
    "fpga",
    "test/cosim",
    "CLAUDE.md",
    "ARCHITECTURE.md",
    "README.md",
    "setup.sh",
    "Makefile",
)

# Binaries the eval shells out to. Resolved through PATH at snapshot time;
# a replaced binary (size/mtime) or a new binary shadowing it earlier on
# PATH (different resolved path) both show up as a change.
EVAL_TOOLS = (
    "yosys",            # riscv-formal (sby) only; V2 does not synthesize with it
    "verilator",
    "sby",
    "yosys-smtbmc",
    "bitwuzla",
    "riscv32-unknown-elf-gcc",
)

# Ignored paths inside a slot worktree that survive the pre-build purge.
# Agent transcripts are tailed live and read after the slot; the notes are
# read into the log entry; the riscv-formal symlink is how formal finds
# the framework (its target is covered by the snapshot). Nothing here is
# read by lint, synth, bench, cosim, formal or FPGA eval.
_KEEP_IGNORED = (
    "formal/riscv-formal",
    ".agent.log",
    ".agent.last",
    ".claude.log",
    ".scribe.log",
    ".pi-sessions",
)


def _keep(path: str, target: str | None) -> bool:
    path = path.rstrip("/")
    name = path.rsplit("/", 1)[-1]
    if path in _KEEP_IGNORED or path == "implementation_notes.md":
        return True
    if target and path == f"cores/{target}/implementation_notes.md":
        return True
    # .agent.<phase>.log / .agent.<phase>.last / .scribe.<n>.last
    if "/" not in path and (name.startswith(".agent.") or name.startswith(".scribe.")):
        return True
    return False


# Files the harness itself writes into a checkout while an agent runs (its
# transcripts, formal logs, run summary, bytecode). Every sandbox check
# tolerates these by name, so they no longer have to be gitignored to
# avoid false `sandbox_violation`s. None of them is read by an eval gate.
# If the harness grows a new output, add it HERE (not only to .gitignore).
HARNESS_OUTPUTS = (
    re.compile(r"(^|/)\.agent(\.[^/]+)?\.(log|last)$"),
    re.compile(r"(^|/)\.scribe(\.[^/]+)?\.(log|last)$"),
    re.compile(r"(^|/)\.claude\.log$"),
    re.compile(r"^formal/last_run(-\d+)?\.log$"),
    re.compile(r"^cores/[^/]+/experiments/run_summary\.json$"),
    re.compile(r"(^|/)__pycache__/"),
    re.compile(r"\.pyc$"),
)


def is_harness_output(path: str) -> bool:
    return any(p.search(path) for p in HARNESS_OUTPUTS)


def dirty_state(repo: str | Path = ".") -> dict[str, str]:
    """{path: content hash} for every modified, deleted or untracked
    (not ignored) path in the checkout. Renames appear as delete + add."""
    out = subprocess.run(
        ["git", "-C", str(repo), "status", "--porcelain", "-z",
         "--untracked-files=all", "--no-renames"],
        capture_output=True, text=True, check=True,
    ).stdout
    root = Path(repo)
    state = {}
    for entry in out.split("\0"):
        if len(entry) < 4:
            continue
        path = entry[3:]
        state[path] = _hash_file(root / path)
    return state


def changed_since(before: dict[str, str], after: dict[str, str],
                  allowed) -> list[str]:
    """Paths whose dirty state changed between two dirty_state() calls,
    minus those `allowed(path)` accepts and harness outputs.

    Comparing against a pre-agent baseline (instead of reading `git status`
    absolutely) means pre-existing dirt, e.g. a maintainer's uncommitted
    work in a dev checkout, is neither blamed on nor reverted for the agent.
    """
    return sorted(p for p in before.keys() | after.keys()
                  if before.get(p) != after.get(p)
                  and not allowed(p) and not is_harness_output(p))


def revert_paths(paths: list[str], before: dict[str, str],
                 repo: str | Path = ".") -> list[str]:
    """Undo an agent's breaches: restore tracked files to HEAD and delete
    new untracked ones. A path that was already dirty before the agent ran
    is left alone (restoring it to HEAD would destroy someone's work);
    those are returned so the caller can report them."""
    root = Path(repo)
    left = []
    for p in paths:
        if p in before:
            left.append(p)
            continue
        tracked = subprocess.run(
            ["git", "-C", str(root), "ls-files", "--error-unmatch", "--", p],
            capture_output=True,
        ).returncode == 0
        if tracked:
            subprocess.run(["git", "-C", str(root), "checkout", "HEAD", "--", p],
                           capture_output=True)
        else:
            (root / p).unlink(missing_ok=True)
    return left


def ignored_paths(worktree: str | Path) -> list[str]:
    """Every gitignored path in the worktree, directories collapsed."""
    out = subprocess.run(
        ["git", "-C", str(worktree), "ls-files", "-z", "--others", "--ignored",
         "--exclude-standard", "--directory"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [p for p in out.split("\0") if p]


def purge_ignored_outputs(worktree: str | Path, target: str | None = None) -> list[str]:
    """Delete every gitignored path in the worktree except the keep-list.

    Returns the purged paths (relative), for logging. Symlinks are unlinked,
    never followed.
    """
    root = Path(worktree)
    purged = []
    for rel in ignored_paths(root):
        if _keep(rel, target):
            continue
        p = root / rel.rstrip("/")
        if p.is_symlink() or p.is_file():
            p.unlink(missing_ok=True)
        elif p.is_dir():
            shutil.rmtree(p, ignore_errors=True)
        else:
            continue
        purged.append(rel)
    return purged


def _hash_file(p: Path) -> str:
    if p.is_symlink():
        return "link:" + os.readlink(p)
    if not p.exists():
        return "<missing>"
    if p.is_dir():
        return "<dir>"
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _contract_fingerprint(root: Path) -> dict[str, str]:
    """{relpath: content hash} over tracked + untracked-not-ignored files
    under CONTRACT_PATHS. Deleted tracked files hash to '<missing>'."""
    paths = [p for p in CONTRACT_PATHS if (root / p).exists() or (root / p).is_symlink()]
    if not paths:
        return {}
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others",
         "--exclude-standard", "--", *paths],
        capture_output=True, text=True, check=True,
    ).stdout
    files = sorted({p for p in out.split("\0") if p})
    return {f: _hash_file(root / f) for f in files}


def _riscv_formal_fingerprint(root: Path, rf: Path | None = None,
                              label: str = "riscv-formal") -> dict[str, str]:
    """HEAD + dirty paths of the (possibly shared) riscv-formal checkout.

    `cores/` is excluded: formal/run_all.sh stages each run under
    cores/<CORE_NAME>-<pid>/ there, and concurrent slots do so legitimately.
    """
    rf = rf or root / "formal" / "riscv-formal"
    if not rf.exists():
        return {}
    rf = rf.resolve()
    # Check for rf's own .git explicitly: without one, `git -C rf` would
    # silently answer for the enclosing checkout (where rf is ignored).
    head = subprocess.run(
        ["git", "-C", str(rf), "rev-parse", "HEAD"],
        capture_output=True, text=True,
    ) if (rf / ".git").exists() else None
    if head is None or head.returncode != 0:
        # Not a git checkout (e.g. a tarball copy): hash the generator
        # inputs directly instead.
        fp = {}
        for sub in ("checks", "insns"):
            base = rf / sub
            if base.is_dir():
                for f in sorted(base.rglob("*")):
                    if f.is_file() and "__pycache__" not in f.parts:
                        fp[f"{label}/{f.relative_to(rf)}"] = _hash_file(f)
        return fp
    fp = {f"{label}@HEAD": head.stdout.strip()}
    status = subprocess.run(
        ["git", "-C", str(rf), "status", "--porcelain", "-z",
         "--untracked-files=all", "--no-renames", "--", ".", ":(exclude)cores"],
        capture_output=True, text=True, check=True,
    ).stdout
    for entry in status.split("\0"):
        if len(entry) < 4:
            continue
        path = entry[3:]
        fp[f"{label}/{path}"] = _hash_file(rf / path)
    return fp


def _toolchain_fingerprint() -> dict[str, str]:
    fp = {}
    # The vendor FPGA flow lives outside PATH (tools/eval/gowin.py).
    from tools.eval.gowin import GOWIN_HOME
    for name in ("gw_sh", "GowinSynthesis"):
        p = GOWIN_HOME / "IDE" / "bin" / name
        try:
            st = p.resolve().stat()
            fp[f"gowin:{name}"] = f"{p.resolve()}:{st.st_size}:{st.st_mtime_ns}"
        except OSError:
            fp[f"gowin:{name}"] = "<absent>"
    for tool in EVAL_TOOLS:
        where = shutil.which(tool)
        if where is None:
            fp[f"tool:{tool}"] = "<absent>"
            continue
        real = Path(where).resolve()
        try:
            st = real.stat()
            fp[f"tool:{tool}"] = f"{real}:{st.st_size}:{st.st_mtime_ns}"
        except OSError:
            fp[f"tool:{tool}"] = f"{real}:<unreadable>"
    return fp


def take_snapshot(root: str | Path = ".") -> dict[str, str]:
    """Fingerprint everything outside the worktree the eval depends on."""
    root = Path(root).resolve()
    return {
        **_contract_fingerprint(root),
        **_riscv_formal_fingerprint(root),
        **_riscv_formal_fingerprint(root, root / EVAL_RISCV_FORMAL,
                                    "riscv-formal-eval"),
        **_toolchain_fingerprint(),
    }


# A harness-only riscv-formal copy (bench clones make one). Agents run
# their own formal self-checks in formal/riscv-formal; the eval runs
# against this copy instead. formal/run_all.sh reaps per-PID work dirs
# whose `kill -0` fails, and from inside an agent sandbox kill -0 on any
# outside PID fails, so a shared copy let an agent's self-check delete
# the harness's live formal run (2026-09-26 incident).
EVAL_RISCV_FORMAL = Path(".tmp") / "riscv-formal-eval"


def use_eval_riscv_formal(worktree: str | Path, root: str | Path = ".") -> bool:
    """Point the worktree's riscv-formal symlink at the harness-only copy,
    when one exists. Called after the agent finishes, before formal."""
    src = Path(root) / EVAL_RISCV_FORMAL
    link = Path(worktree) / "formal" / "riscv-formal"
    if not src.is_dir() or not link.is_symlink():
        return False
    link.unlink()
    link.symlink_to(src.resolve())
    return True


def snapshot_changes(before: dict[str, str], after: dict[str, str]) -> list[str]:
    """Keys added, removed, or whose fingerprint changed, sorted."""
    return sorted(k for k in before.keys() | after.keys()
                  if before.get(k) != after.get(k))
