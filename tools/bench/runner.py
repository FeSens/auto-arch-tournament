"""Bench matrix runner.

Drives the LLM benchmark: enumerates (model, rep) jobs from
tools/bench/models.yaml, clones the configured ref (default: main)
into an isolated per-job directory, drives tools.orchestrator
with the model's runtime AGENT_PROVIDER (codex / opencode / claude),
then summarizes the result and appends a row to bench/results.jsonl.

The default ref was previously `bench-fixture-v1` (the orphan fixture
branch); after the nret-adapter + reliability work merged to main,
main is the canonical source and the orphan is no longer needed.
Override with --ref for reproducing a specific historical snapshot.

Resumable: re-running skips (model, rep) pairs already in results.jsonl.

Usage:
    python -m tools.bench.runner                                  # full matrix
    python -m tools.bench.runner --reps 1 --only opus-47          # subset
    python -m tools.bench.runner --parallel 3 --max-cost 50       # 3 in parallel
    python -m tools.bench.runner --dry-run                        # plan only
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import signal
import queue
import subprocess
import threading
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import yaml

from tools.bench import preflight
from tools.bench.telemetry import (  # noqa: F401  (re-exported)
    collect_agent_logs,
    parse_codex_cost_from_log,
    parse_cost_from_log,
    parse_opencode_cost_from_log,
    reconstruct_log_from_git,
    summarize_run,
)
from tools.bench.transcript import publish_transcript
from tools.sandbox import EVAL_RISCV_FORMAL
from tools.eval._subprocess import install_tree_reaper, kill_process_tree


HERE = Path(__file__).parent
REPO_ROOT = HERE.parent.parent
DEFAULT_MODELS_YAML = HERE / "models.yaml"
DEFAULT_REF = "main"
DEFAULT_RESULTS_JSONL = REPO_ROOT / "bench" / "results.jsonl"
DEFAULT_CLONE_BASE = REPO_ROOT / ".claude" / "bench-runs"

# V2 isolation (research/v2/scripts/setup_bench_user.sh): with
# HWE_AGENT_USER set, the runner stays the operator and only the agent
# CLIs run as that account, which cannot read the operator's home. The
# account shares one directory with the operator: clones, a copy of the
# toolchain, and the pinned CLI binaries.
# macOS: research/v2/scripts/setup_bench_user.sh; Linux (the V2 run host):
# research/v2/scripts/setup_server.sh, which adds a shared venv.
IS_MAC = sys.platform == "darwin"
AGENT_SHARED = Path("/Users/Shared/hwebench") if IS_MAC else Path("/srv/hwebench")
_DIR_ACE = ("list,add_file,search,delete,add_subdirectory,delete_child,readattr,"
            "writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit")
_FILE_ACE = "read,write,append,execute,delete,readattr,writeattr,readextattr,writeextattr,readsecurity"


@dataclass(frozen=True)
class AgentUser:
    name: str
    uid: int
    home: Path
    shared: Path = AGENT_SHARED

    @property
    def local(self) -> Path:
        """Copy of the operator's ~/.local pieces the agents need (sby,
        cocotb), used as PYTHONUSERBASE."""
        return self.shared / "local"

    @property
    def path(self) -> str:
        tc = self.shared / "toolchain"
        dirs = [self.shared / "bin", self.shared / "venv" / "bin", self.local / "bin",
                tc / "oss-cad-suite" / "bin", tc / "bin"]
        py = shutil.which("python3")
        if py and not Path(py).resolve().is_relative_to(Path.home()):
            dirs.append(Path(py).parent)
        return ":".join([*map(str, dirs), "/opt/homebrew/bin", "/usr/bin", "/bin",
                         "/usr/sbin", "/sbin"])

    def read_roots(self) -> list[str]:
        from tools.eval.gowin import GOWIN_HOME
        roots = [str(GOWIN_HOME)] if GOWIN_HOME.is_dir() else []
        for d in ("toolchain", "local", "bin", "venv"):
            p = self.shared / d
            if p.exists():
                roots.append(str(p))
                if p.resolve() != p:
                    roots.append(str(p.resolve()))
        return roots

    def cli_versions(self, cli_dir: Path | None = None) -> dict:
        """Versions of the pinned CLIs; a model's own CLI dir (ModelEntry.
        cli_dir) overrides the one it holds."""
        out = {}
        for d in (self.shared / "bin", cli_dir):
            if d is None:
                continue
            try:
                out["claude_cli"] = (d / "claude.version").read_text().strip()
            except OSError:
                pass
            try:
                out["codex_cli"] = json.loads(
                    (d / "codex.version.json").read_text()).get("version")
            except (OSError, ValueError):
                pass
        return out


def agent_pool() -> list[AgentUser]:
    """HWE_AGENT_USER: one account, or a comma-separated pool. Each running
    job holds its own account (acquire_agent), so concurrent runs cannot
    read each other's clones, homes, temp files or processes."""
    import pwd
    out = []
    for name in os.environ.get("HWE_AGENT_USER", "").split(","):
        name = name.strip()
        if name:
            pw = pwd.getpwnam(name)
            out.append(AgentUser(name=name, uid=pw.pw_uid, home=Path(pw.pw_dir),
                                 shared=AGENT_SHARED))
    return out


_JOB = threading.local()
_FREE_AGENTS: "queue.Queue[AgentUser] | None" = None
_FREE_LOCK = threading.Lock()


def agent_user() -> Optional[AgentUser]:
    """The account of the job running on this thread, else the pool's first."""
    held = getattr(_JOB, "agent", None)
    if held is not None:
        return held
    pool = agent_pool()
    return pool[0] if pool else None


def run_home(agent: AgentUser, slug: str) -> Path:
    """Per-run HOME (Claude's ~/.claude transcripts, caches, shell state).
    The account's real home only holds its Codex login."""
    return agent.shared / "homes" / slug


def run_tmp(agent: AgentUser, slug: str) -> Path:
    """Per-run base of the agents' private TMPDIRs (tools/agents/_runtime.py
    run_agent_streaming). Outside the clone and the same length for every
    run: Claude Code's sandbox sockets live in TMPDIR and a Unix socket path
    may not exceed 107 bytes; under the clone the length grew with the
    system's name, and a TMPDIR under the worktree left Claude's sandbox
    unable to start (V2 incident 06)."""
    return agent.shared / "tmp" / hashlib.sha1(slug.encode()).hexdigest()[:8]


def reset_agent(agent: AgentUser, homes: tuple[Path, ...] = ()) -> None:
    """Leave nothing of a finished run for the account's next run: its
    processes, the given per-run homes (the homes directory is not
    listable, so they are named) and its files in the shared temp dirs."""
    as_agent(agent.name, "/usr/bin/pkill", "-KILL", "-u", agent.name, capture_output=True)
    script = ('for d in /tmp /var/tmp /dev/shm; do '
              'find "$d" -mindepth 1 -maxdepth 1 -user "$1" -exec rm -rf {} + 2>/dev/null; done; '
              'shift; rm -rf "$@"; true')
    as_agent(agent.name, "/bin/sh", "-c", script, "sh", agent.name, *map(str, homes),
             capture_output=True)


def acquire_agent() -> Optional[AgentUser]:
    global _FREE_AGENTS
    with _FREE_LOCK:
        if _FREE_AGENTS is None:
            pool = agent_pool()
            if not pool:
                return None
            _FREE_AGENTS = queue.Queue()
            for a in pool:
                _FREE_AGENTS.put(a)
    agent = _FREE_AGENTS.get()
    _JOB.agent = agent
    return agent


def release_agent(agent: Optional[AgentUser], clone: Path) -> None:
    """Revoke the account's access to the finished run's clone, wipe what
    the run left, and hand the account to the next job."""
    _JOB.agent = None
    if agent is None:
        return
    if not IS_MAC and clone.exists():
        # Every path into the clone goes through its top directory.
        subprocess.run(["setfacl", "-x", f"u:{agent.name},d:u:{agent.name}", str(clone)],
                       capture_output=True)
        os.chmod(clone, 0o700)
    reset_agent(agent, (run_home(agent, clone.name), run_tmp(agent, clone.name)))
    from tools.eval._subprocess import remove_path
    remove_path(run_tmp(agent, clone.name), must=False)
    _FREE_AGENTS.put(agent)


def lock_clone_base(base: Path) -> None:
    """Agents may traverse the clone base but not list it; each clone's own
    ACL admits only the account running it."""
    if IS_MAC:
        return
    subprocess.run(["setfacl", "-b", str(base)], capture_output=True)
    os.chmod(base, 0o711)


def check_agent_user(agent: AgentUser) -> Optional[str]:
    """What stops the runner from launching agents as this account, or None."""
    try:
        r = as_agent(agent.name, "/usr/bin/true", capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"sudo failed: {e}"
    if r.returncode != 0:
        return "cannot sudo to it without a password (run setup_bench_user.sh)"
    for d in ("clones", "toolchain", "bin", "local" if IS_MAC else "venv", *(() if IS_MAC else ("homes", "tmp"))):
        if not (agent.shared / d).is_dir():
            return f"{agent.shared / d} missing (run setup_bench_user.sh)"
    if as_agent(agent.name, "/bin/test", "-r", str(Path.home()),
                capture_output=True).returncode == 0:
        return f"it can read {Path.home()}"
    if not IS_MAC:
        return check_agent_slice(agent.name) or check_agent_reaping(agent.name)
    return None


def check_agent_slice(name: str) -> Optional[str]:
    """None if agent commands launched for this account land in its CPU
    slice (equal share per concurrent run; setup_server.sh, 6d)."""
    from tools.agents._runtime import agent_launch_prefix
    want = f"/hweagents.slice/hweagents-{name}.slice/"
    try:
        r = subprocess.run([*agent_launch_prefix(name), "/bin/cat", "/proc/self/cgroup"],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"CPU slice check failed: {e}"
    if want not in r.stdout:
        return (f"its commands do not run in {want.strip('/')} "
                f"(got {r.stdout.strip() or r.stderr.strip()!r}; run setup_server.sh, 6d)")
    return None


def check_agent_reaping(name: str) -> Optional[str]:
    """None if nothing an agent command starts can outlive it: the launch
    helper kills whatever the command left in its scope (setup_server.sh,
    6d), and the account cannot schedule cron or at jobs (6e). V2 incident
    05: an agent's backgrounded formal solvers ran on after the agent."""
    from tools.agents._runtime import agent_launch_prefix
    try:
        r = subprocess.run([*agent_launch_prefix(name), "/bin/sh", "-c",
                            "sleep 300 >/dev/null 2>&1 & echo $!"],
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"leftover-process check failed: {e}"
    pid = r.stdout.strip()
    if not pid.isdigit():
        return f"leftover-process check failed: {r.stdout.strip() or r.stderr.strip()!r}"
    if Path(f"/proc/{pid}").exists():
        as_agent(name, "/bin/kill", "-KILL", pid, capture_output=True)
        return ("a process its command started outlived the command "
                "(install the current hwe-agent-scope: setup_server.sh, 6d)")
    for tool in ("/usr/bin/crontab", "/usr/bin/at"):
        if not Path(tool).exists():
            continue
        r = as_agent(name, tool, "-l", capture_output=True, text=True)
        if "not allowed" not in r.stderr and "permission" not in r.stderr.lower():
            return f"it may schedule jobs with {tool} (setup_server.sh, 6e)"
    return None


def as_agent(user: str, *cmd: str, **kw) -> subprocess.CompletedProcess:
    import getpass
    if user == getpass.getuser():   # tests run the "agent" as themselves
        return subprocess.run(list(cmd), **kw)
    return subprocess.run(["sudo", "-n", "-u", user, *cmd], **kw)


def share_with_agent(path: Path, agent: AgentUser) -> None:
    """Give the agent account read/write on everything under path, and
    the operator the same on whatever the agent creates there later
    (inherited ACEs; tempfile.mkdtemp's 0700 dirs included)."""
    op = os.environ.get("USER") or Path.home().name
    if not IS_MAC:
        # POSIX ACLs: access entries on what exists, default entries on
        # directories so new files inherit them.
        spec = ",".join(f"{t}u:{who}:rwX" for who in (agent.name, op) for t in ("", "d:"))
        # No access for "other": the ACL above is the only way in, so other
        # agent accounts (concurrent runs) cannot read the clone. Default
        # "other" entries keep files created later closed too.
        subprocess.run(["chmod", "-R", "o-rwx", str(path)], check=True, capture_output=True)
        subprocess.run(["setfacl", "-R", "-m", f"{spec},d:o::---", str(path)],
                       check=True, capture_output=True)
        return
    for who in (agent.name, op):
        subprocess.run(["find", str(path), "-type", "d", "-exec",
                        "chmod", "+a", f"user:{who} allow {_DIR_ACE}", "{}", "+"],
                       check=True, capture_output=True)
        subprocess.run(["find", str(path), "-type", "f", "-exec",
                        "chmod", "+a", f"user:{who} allow {_FILE_ACE}", "{}", "+"],
                       check=True, capture_output=True)


def lock_from_agent(path: Path, agent: AgentUser) -> None:
    """Make path (the eval's riscv-formal copy) unwritable and
    undeletable for the agent account."""
    if not IS_MAC:
        # No per-entry delete deny on Linux: strip the ACLs inside, and make
        # the parent sticky so the agent can only remove its own entries.
        subprocess.run(["setfacl", "-R", "-b", str(path)], check=True, capture_output=True)
        subprocess.run(["chmod", "-R", "go-w", str(path)], check=True, capture_output=True)
        subprocess.run(["chmod", "+t", str(path.parent)], check=True, capture_output=True)
        return
    subprocess.run(["chmod", "-R", "-N", str(path)], check=True, capture_output=True)
    subprocess.run(["chmod", "-R", "go-w", str(path)], check=True, capture_output=True)
    subprocess.run(["chmod", "+a", f"user:{agent.name} deny delete", str(path)],
                   check=True, capture_output=True)


def rmtree_shared(path: Path) -> None:
    """Delete a clone; anything the agent account left undeletable for
    the operator is removed as that account."""
    shutil.rmtree(path, ignore_errors=True)
    for agent in agent_pool():
        if not path.exists():
            break
        as_agent(agent.name, "/bin/rm", "-rf", str(path), capture_output=True)
        shutil.rmtree(path, ignore_errors=True)
DEFAULT_RESULTS_DIR = REPO_ROOT / "bench"

# Per-rep wall-clock ceiling. 0 = no cap (the runner waits for the
# orchestrator to exit on its own). Originally 9h to bound runaway
# rounds, but legitimate N=10 K=3 runs at xhigh on premium models
# routinely run 4-5h and a stuck-but-still-progressing rep was being
# killed without a clean stop signal. Pass --timeout-sec <N> to
# re-enable the cap for a specific run.
DEFAULT_REP_TIMEOUT_SEC = 0
# Default per-rep cost ceiling (USD).
DEFAULT_MAX_COST_USD = 200.0


@dataclass
class ModelEntry:
    name: str
    # The runtime-specific model identifier. For "codex" it's the codex
    # --model string (e.g. "gpt-5.5"). For "opencode" it's the opencode
    # --model string (e.g. "openai/gpt-5.5", "anthropic/claude-sonnet-4.6").
    # For "claude" it's the claude --model string.
    model: str
    # API-key environment variable name. For OAuth subscription providers
    # (Codex, Claude Pro, Copilot) the auth lives at the runtime's own
    # path (~/.codex/auth.json, ~/.local/share/opencode/auth.json) and no
    # env var is needed — set `oauth: true` and leave key_env empty.
    key_env: str = ""
    oauth: bool = False
    # Agent runtime to use. One of "codex", "opencode", "claude".
    provider: str = "codex"
    # Per-model reasoning effort override. None = use the runtime's
    # default (xhigh for both opencode and codex). For opencode this
    # maps to --variant; for codex it maps to model_reasoning_effort.
    # Set explicitly to "high" for Anthropic/Google routes that don't
    # accept xhigh (opencode silently drops the unknown variant).
    variant: str | None = None
    # Prompt profile: "full" (default) or "naive" (E1c control: strips
    # lesson log, outcomes, metrics, and architecture docs from prompts).
    prompt_profile: str = "full"
    # This model's own agent CLI, when it needs another version than the
    # pinned one in <shared>/bin (a model the pinned CLI cannot reach). A
    # directory, relative to the agent shared dir, laid out like bin/: the
    # provider's executable plus claude.version / codex.version.json. It
    # goes first on the agent's PATH for this model's runs only.
    cli_dir: str | None = None


@dataclass
class JobSpec:
    model: ModelEntry
    rep: int

    @property
    def slug(self) -> str:
        return f"{self.model.name}-rep{self.rep}"


# ---------- model + results loading -------------------------------------


def load_models(path: Path) -> list[ModelEntry]:
    cfg = yaml.safe_load(path.read_text())
    out: list[ModelEntry] = []
    for m in cfg.get("models", []):
        out.append(ModelEntry(
            name=m["name"],
            model=m["model"],
            key_env=m.get("key_env", "") or "",
            oauth=bool(m.get("oauth", False)),
            provider=m.get("provider", "codex"),
            variant=m.get("variant"),
            prompt_profile=m.get("prompt_profile", "full") or "full",
            cli_dir=m.get("cli_dir") or None,
        ))
    if not out:
        raise ValueError(f"{path}: no models defined")
    return out


def model_cli_dir(model: ModelEntry, agent: "AgentUser | None") -> Path | None:
    if not model.cli_dir:
        return None
    return (agent.shared if agent else AGENT_SHARED) / model.cli_dir


def cli_dir_problems(models: list[ModelEntry]) -> list[str]:
    """A model whose CLI dir lacks its provider's CLI would silently run the
    pinned one instead, so the runner refuses to start."""
    out = []
    for m in models:
        d = model_cli_dir(m, agent_user())
        if d is not None and not os.access(d / m.provider, os.X_OK):
            out.append(f"{m.name}: no executable {m.provider} in cli_dir {d}")
    return out


def load_done_set(results_jsonl: Path) -> set[tuple[str, int]]:
    """Return the set of (model, rep) pairs that already have a final row."""
    if not results_jsonl.is_file():
        return set()
    done: set[tuple[str, int]] = set()
    for line in results_jsonl.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        # Only count finalized rows; partial/interrupted rows we want to retry.
        if row.get("status") in ("done", "timed_out", "failed"):
            done.add((row.get("model"), int(row.get("rep", -1))))
    return done


def interleaved_batches(jobs: list[JobSpec]) -> list[list[JobSpec]]:
    """V2 schedule: one batch per rep holding that rep's run of every
    system, started together, so time of day, provider load and host
    contention hit all systems alike. Launch order rotates by rep (with two
    systems: alternates)."""
    by_rep: dict[int, list[JobSpec]] = {}
    for j in jobs:
        by_rep.setdefault(j.rep, []).append(j)
    out = []
    for rep, b in sorted(by_rep.items()):
        r = (rep - 1) % len(b)
        out.append(b[r:] + b[:r])
    return out


def enumerate_jobs(
    models: list[ModelEntry],
    reps: int,
    done: set[tuple[str, int]],
    only_models: Optional[list[str]] = None,
) -> list[JobSpec]:
    jobs: list[JobSpec] = []
    for m in models:
        if only_models and m.name not in only_models:
            continue
        for r in range(1, reps + 1):
            if (m.name, r) in done:
                continue
            jobs.append(JobSpec(model=m, rep=r))
    return jobs


# ---------- env / key helpers -------------------------------------------


def validate_keys(jobs: list[JobSpec], env: dict[str, str]) -> list[str]:
    """Return list of missing env vars (one entry per unique missing var).

    OAuth-subscription jobs (oauth=True) don't need an env var — they
    read credentials from the runtime's own auth file (e.g.
    ~/.codex/auth.json, ~/.local/share/opencode/auth.json) — so they're
    skipped.
    """
    needed = sorted({j.model.key_env for j in jobs
                     if not j.model.oauth and j.model.key_env})
    return [k for k in needed if not env.get(k)]


def load_keyfile(path: Path) -> dict[str, str]:
    """Parse a simple KEY=value file. Lines starting with # are comments."""
    if not path.is_file():
        return {}
    out: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        # Strip surrounding quotes if any.
        v = v.strip()
        if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
            v = v[1:-1]
        out[k.strip()] = v
    return out


# ---------- per-job execution -------------------------------------------


def find_riscv_formal() -> Path | None:
    """Locate the riscv-formal checkout for symlinking into bench clones.

    `formal/riscv-formal/` is a gitignored vendored submodule (~200 MB).
    The fixture branch can't include it, so each clone needs a symlink
    to a real checkout. We look in: (1) <REPO_ROOT>/formal/riscv-formal,
    (2) any ancestor of REPO_ROOT that contains formal/riscv-formal
    (handles the case where the runner is invoked from a git worktree
    that doesn't have the submodule but its parent main-repo does).
    """
    candidate = REPO_ROOT / "formal" / "riscv-formal"
    if candidate.is_dir():
        return candidate
    cur = REPO_ROOT.resolve()
    for _ in range(8):
        cur = cur.parent
        candidate = cur / "formal" / "riscv-formal"
        if candidate.is_dir():
            return candidate
        if cur == cur.parent:
            break
    return None


def provenance(repo_root: Path, ref: str) -> dict:
    """Commits behind a rep: the fixture ref it evaluates with, and the
    runner checkout (cost parsing, summaries) that drove it."""
    def git(*args: str) -> str:
        r = subprocess.run(["git", "-C", str(repo_root), *args],
                           capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else ""
    dirty = git("status", "--porcelain", "--", "tools")
    return {
        "fixture_ref": ref,
        "fixture_commit": git("rev-parse", f"{ref}^{{commit}}") or None,
        "runner_commit": git("rev-parse", "HEAD") or None,
        "runner_dirty": bool(dirty),
        "harness_version": preflight.harness_version(),
    }


# What an agent's clone contains: its target core and the contract the
# evaluator runs, nothing else (an allowlist; V2.1). V1 used a denylist
# and deliberately kept other material; V2's leak audit
# (research/v2/LEAKS.md) found it handed agents prior results: README.md
# lists V1's accepted winners in merge order, cores/v1/ holds V1's
# champion RTL and its full hypothesis log, and the reference cores and
# other paths are prior designs tuned to V1's timer. Held-out kernels
# (bench/holdout) and every published result are outside the list too.
_AGENT_VISIBLE = {
    ".": {".git", ".gitignore", ".gitmodules", "CLAUDE.md", "ARCHITECTURE.md", "Makefile",
          "setup.sh", "LICENSE", "NOTICE", "cores", "bench", "formal", "fpga", "schemas",
          "test", "tools"},
    "cores": {"bench"},
    "bench": {"programs"},
    "tools": {"HARNESS_VERSION", "__init__.py", "accept_rule.py", "agents", "eval",
              "orchestrator.py", "plot.py", "sandbox.py", "tournament.py", "worktree.py"},
}


def agent_invisible_paths(dest: Path) -> list[str]:
    """Repo-relative paths clone_fixture strips from a fixture clone:
    everything outside _AGENT_VISIBLE."""
    paths = []
    for parent, keep in _AGENT_VISIBLE.items():
        d = dest / parent
        if d.is_dir():
            paths += sorted(str((d / p.name).relative_to(dest)) for p in d.iterdir()
                            if p.name not in keep)
    return paths


def clone_fixture(repo_root: Path, ref: str, dest: Path) -> None:
    if dest.exists():
        # Prefer to delete and re-clone for reproducibility — a stale
        # half-built clone is worse than the few seconds spent re-cloning.
        rmtree_shared(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["git", "clone", "--depth", "1", "--branch", ref, "--single-branch",
         str(repo_root), str(dest)],
        check=True, capture_output=True,
    )
    # Sever every path back to the source's history before rewriting the
    # branch below. `git clone` copies tags and leaves an `origin` remote
    # with remote-tracking refs; both keep the pre-strip commits (and any
    # bench/holdout blobs they carry) reachable inside the clone even
    # after `git reset --hard` moves the branch. Delete all tags and drop
    # origin so the local branch we reset is the only surviving ref.
    #
    # Deleting all tags also subsumes the old branch/tag disambiguation
    # fix: the parent repo can have BOTH a branch named bench-fixture-v1
    # AND a tag of the same name (the tag pins the fixture freeze commit;
    # the branch advances). git clone copies both, and `git checkout
    # <ref>` in accept_worktree (tools/worktree.py:_active_branch) then
    # silently resolved to the TAG, detaching HEAD and orphaning every
    # log.jsonl commit appended since the pre-create, observed as
    # "iter=9" / "iter=27" in N=10 K=3 runs that ran all 30 slots. With
    # no tags left in the clone, `<ref>` is unambiguous.
    tags = subprocess.run(
        ["git", "tag", "-l"], cwd=str(dest), capture_output=True, text=True,
    ).stdout.split()
    if tags:
        subprocess.run(
            ["git", "tag", "-d", *tags],
            cwd=str(dest), check=False, capture_output=True,
        )
    subprocess.run(
        ["git", "remote", "remove", "origin"],
        cwd=str(dest), check=False, capture_output=True,
    )
    # E3 prereg guard: held-out kernels must never be visible to
    # optimization agents. bench/holdout/ is a fixture-visible directory
    # (tracked so bench/holdout/Makefile + evaluator tooling can use it
    # outside the agent-facing clones), but any clone_fixture output is
    # handed straight to a hypothesis-implementation agent, so strip it
    # unconditionally regardless of which ref was cloned.
    #
    # A commit-on-top strip is NOT enough. tools/worktree.py's
    # create_worktree cuts each hypothesis worktree straight from this
    # clone's git objects (`git worktree add -b <branch> <path>
    # <base_branch>`), and repo.bundle (`git bundle create --all`, in
    # run_one_job) captures every reachable commit. If any reachable
    # commit still carried bench/holdout, a worktree could recover the
    # kernels with `git show HEAD~1:bench/holdout/...` or `git checkout
    # <rev> -- bench/holdout`, and the bundle would ship them. So remove
    # holdout from the index, then collapse the clone's whole pre-run
    # history to a single PARENTLESS root commit built from the stripped
    # tree: no reachable commit ever contained bench/holdout, and there
    # is no HEAD~1 to resurrect.
    #
    # --ignore-unmatch keeps the index strip a no-op for refs that never
    # had bench/holdout; the single-root rebuild still runs for them, so
    # every clone has the same neutral shape and the guard's existence is
    # not advertised in a `git log` where no kernels were present.
    #
    # The same structural strip removes every published result of this
    # benchmark (agent_invisible_paths): with `--ref main` the fixture
    # carries bench/<model>/rep*/ journals + transcripts, the leaderboard,
    # results.jsonl, the research diary, docs and the site. Agents were
    # observed listing bench/<model>/rep*/log.jsonl with `rg --files`,
    # i.e. other runs' winning ideas were one `cat` away.
    for rel in agent_invisible_paths(dest):
        subprocess.run(
            ["git", "rm", "-r", "-q", "--cached", "--ignore-unmatch", "--", rel],
            cwd=str(dest), check=True, capture_output=True,
        )
        target = dest / rel
        if target.is_dir() and not target.is_symlink():
            shutil.rmtree(target, ignore_errors=True)
        else:
            target.unlink(missing_ok=True)
    # Pre-create cores/bench/experiments/ as a tracked directory so the
    # orchestrator can `git add` files into it without the sandbox check
    # tripping on the untracked parent dir. The fixture stripped this
    # directory deliberately to keep reps from inheriting each other's
    # state, so we add it back per-clone with a single .gitkeep file.
    # Staged now so it lands in the single root commit built below,
    # keeping the pre-run history at exactly one commit.
    exp_dir = dest / "cores" / "bench" / "experiments"
    exp_dir.mkdir(parents=True, exist_ok=True)
    (exp_dir / ".gitkeep").touch()
    subprocess.run(
        ["git", "add", "cores/bench/experiments/.gitkeep"],
        cwd=str(dest), check=True, capture_output=True,
    )
    # Build the parentless root from the current (stripped, gitkeep-added)
    # index and move the branch onto it. `git write-tree` snapshots the
    # index; `git commit-tree <tree>` with no -p makes an orphan commit;
    # `git reset --hard` repoints the checked-out branch (the working
    # tree already matches, so nothing is touched on disk). commit-tree
    # does not honor commit.gpgsign, so no signing override is needed; we
    # still pass the bench-runner committer identity so the commit
    # succeeds on machines with no global user.name/email. The message is
    # deliberately neutral ("bench fixture root") and never mentions
    # holdout.
    tree = subprocess.run(
        ["git", "write-tree"],
        cwd=str(dest), check=True, capture_output=True, text=True,
    ).stdout.strip()
    root = subprocess.run(
        ["git", "-c", "user.email=bench-runner@local",
         "-c", "user.name=bench-runner",
         "commit-tree", tree, "-m", "bench fixture root"],
        cwd=str(dest), check=True, capture_output=True, text=True,
    ).stdout.strip()
    subprocess.run(
        ["git", "reset", "--hard", root],
        cwd=str(dest), check=True, capture_output=True,
    )
    # Prune the now-orphaned pre-strip commits (and their bench/holdout
    # blobs) from the clone's object store so they cannot be recovered via
    # the reflog, `git cat-file`, or repo.bundle. A local clone hardlinks
    # the source's packs; gc here repacks only the clone's reachable
    # objects and unlinks the old pack. The source repo's own objects are
    # untouched because it keeps its own refs.
    subprocess.run(
        ["git", "reflog", "expire", "--expire=now", "--all"],
        cwd=str(dest), check=False, capture_output=True,
    )
    subprocess.run(
        ["git", "gc", "--prune=now", "--quiet"],
        cwd=str(dest), check=False, capture_output=True,
    )
    # Various per-clone artifacts must be invisible to the orchestrator's
    # `git status --porcelain` sandbox check (tools/agents/hypothesis.py:
    # _git_offlimits_changes), or the check treats them as untracked
    # off-limits writes and tries to unlink them (which fails on
    # directories with EPERM on macOS). Use git's per-clone exclude file
    # so we don't have to mutate any committed .gitignore.
    exclude_path = dest / ".git" / "info" / "exclude"
    exclude_path.parent.mkdir(parents=True, exist_ok=True)
    extras = (
        "\n# bench runner — keep these out of git status / sandbox\n"
        ".tmp/\n.codex-home/\n__pycache__/\n*.pyc\n"
        # Claude Code's Linux sandbox (bubblewrap) mounts over these names
        # and leaves empty placeholder files in the directory a command runs
        # from while it runs. Hypothesis agents share the clone root, so one
        # agent's check saw another's live placeholders and was rolled back
        # as an off-limits write (4 of 15 Opus hypothesis slots in the first
        # V2.1 batch; Codex is unaffected). Ignored paths never reach the
        # eval: purge_ignored_outputs deletes them before every build.
        ".bash_profile\n.bashrc\n.gitconfig\n.gitmodules\n.idea\n.mcp.json\n"
        ".profile\n.ripgreprc\n.vscode\n.zprofile\n.zshrc\n"
        # Cocotb pytest writes test/results.xml when the impl agent runs
        # `make test` locally to validate. The orchestrator's sandbox
        # only allows test_*.py changes, so an unignored results.xml
        # trips sandbox_violation. The file is regenerable artifact.
        "cores/bench/test/results.xml\n"
        "cores/bench/test/*.result.xml\n"
        "test/results.xml\n"
        "test/*.result.xml\n"
        # install_opencode_config writes opencode.json into the clone
        # root and the opencode CLI rewrites it during a session
        # (config sync / session state). The hypothesis sandbox check
        # runs `git status --porcelain` and any untracked / modified
        # path that isn't the round's pre-allocated YAML is treated
        # as an off-limits write — opencode.json then trips a false
        # `hypothesis_gen_failed` breach, marking the slot broken even
        # though the agent never touched it. Excluding it here keeps
        # opencode.json out of git status entirely. The opencode-side
        # deny rule (in install_opencode_config) is the second layer
        # that prevents the agent from actually editing it.
        "opencode.json\n"
        # Opencode rewrites session state under .opencode/ during a
        # run. Excluding the whole tree keeps those mutations off the
        # sandbox check.
        ".opencode/\n"
    )
    with exclude_path.open("a") as f:
        f.write(extras)
    # If the fixture happens to have committed pyc files (an artifact of
    # an earlier fixture build), tell git to ignore future changes to
    # them via `assume-unchanged`. Without this, Python's import cache
    # rewrites the bytecode and the orchestrator's sandbox flags the
    # changed files as off-limits writes.
    tracked = subprocess.run(
        ["git", "ls-files"], cwd=str(dest), capture_output=True, text=True,
    ).stdout.splitlines()
    pyc_paths = [p for p in tracked if p.endswith(".pyc") or "/__pycache__/" in p]
    if pyc_paths:
        subprocess.run(
            ["git", "update-index", "--assume-unchanged", *pyc_paths],
            cwd=str(dest), capture_output=True,
        )
    # Mirror riscv-formal into the clone as a *real* directory. The
    # submodule is ~200 MB and gitignored, so it isn't in the fixture;
    # without it, `make formal` fails with "formal/riscv-formal not
    # found" and every iteration is marked broken at the formal gate.
    #
    # Why a copy instead of a symlink: the bench rep is a *standalone*
    # `git clone`, not a `git worktree add`. Codex's
    # `--sandbox workspace-write` resolves the workspace root to this
    # rep clone, and a symlink whose target lives outside that root
    # (the parent repo's vendored riscv-formal) is read-only from the
    # agent's perspective. The orchestrator log on a recent broken
    # bench slot makes this explicit:
    #     "The repository's formal/riscv-formal/cores/bench staging
    #      area is read-only in this sandbox, so the direct formal
    #      script can't write..."
    # The agent then burns dozens of shell calls building a /tmp
    # mirror as workaround instead of fixing the RTL, and the
    # orchestrator's hard formal gate is the first thing to see the
    # bug. A real in-clone copy keeps riscv-formal inside the
    # sandboxed root so `bash formal/run_all.sh` works in-loop.
    # Opencode's permission system has the same workspace-root
    # property, so the fix benefits both workflow-trained runtimes.
    #
    # tools/worktree.py's per-iteration sub-worktree symlink uses
    # Path("formal/riscv-formal").resolve(), which now resolves to a
    # path inside this rep clone — so the sub-worktree symlink target
    # is also inside the workspace root, and no further change is
    # needed there.
    #
    # Cost: measured 5.4 GB (not the originally-estimated ~200 MB) before
    # the formal/riscv-formal work-dir garbage was pruned (task-7 Step 1):
    # years of stale per-PID SBY work dirs accumulate under
    # riscv-formal/cores/ and get carried into every `cp -R`'d clone. On
    # macOS APFS, `cp -Rc` (clonefile(2)) is copy-on-write: ~zero extra
    # disk and ~instant regardless of source size. Fall back to plain
    # `cp -R` off-macOS (GNU coreutils has no `-c` flag) or if clonefile
    # isn't supported on the underlying filesystem. Either way, never
    # inherit a prior run's SBY work dirs into a fresh rep clone.
    rf_src = find_riscv_formal()
    # Two copies: formal/riscv-formal for the agents' own formal runs, and
    # a harness-only one the eval uses (tools/sandbox.py EVAL_RISCV_FORMAL).
    # Without a checkout (unit tests) there is nothing to copy, but the
    # clone is still granted to the account below: an early return here
    # once skipped that and left the agent unable to write its clone.
    for rf_dest in ((dest / "formal" / "riscv-formal", dest / EVAL_RISCV_FORMAL)
                    if rf_src is not None else ()):
        rf_dest.parent.mkdir(parents=True, exist_ok=True)
        if not rf_dest.exists():
            # APFS clonefile (cp -c) is copy-on-write: ~zero extra disk
            # and ~instant. Fall back to plain cp -R off-macOS.
            cp_cow = subprocess.run(
                ["cp", "-Rc", str(rf_src.resolve()), str(rf_dest)],
                capture_output=True)
            if cp_cow.returncode != 0:
                # cp -Rc may have partially created rf_dest before
                # failing. `cp -R src dest` treats an existing dest as a
                # target directory and nests the copy as
                # dest/<src-basename>/... instead of a flat copy, so
                # clear any partial result before falling back.
                shutil.rmtree(rf_dest, ignore_errors=True)
                subprocess.run(
                    ["cp", "-R", str(rf_src.resolve()), str(rf_dest)],
                    check=True)
        # Never inherit prior runs' SBY work dirs into a fresh rep.
        for junk in rf_dest.glob("cores/*-[0-9]*"):
            shutil.rmtree(junk, ignore_errors=True)
    agent = agent_user()
    if agent:
        share_with_agent(dest, agent)
        if (dest / EVAL_RISCV_FORMAL).exists():
            lock_from_agent(dest / EVAL_RISCV_FORMAL, agent)


def install_opencode_config(clone: Path) -> None:
    """Render <clone>/opencode.json with a deny list mirroring the
    bench-fence's intent — block edits to other cores, prevent
    history-rewriting git operations, and otherwise allow normal
    workflow.

    The standalone shallow clone already physically removes other cores
    (cores/baseline, cores/v1) — these rules are belt-and-suspenders
    against any path the agent might construct or any future fixture
    that re-includes other cores.
    """
    cfg = {
        "$schema": "https://opencode.ai/config.json",
        "permission": {
            "edit": {
                "*": "allow",
                "cores/baseline/**": "deny",
                "cores/v1/**": "deny",
                "cores/bench-*/**": "deny",
                "tools/**": "deny",
                "schemas/**": "deny",
                "formal/run_all.sh": "deny",
                "formal/wrapper.sv": "deny",
                "formal/checks.cfg": "deny",
                "fpga/**": "deny",
                "test/cosim/**": "deny",
                "Makefile": "deny",
                "CLAUDE.md": "deny",
                "ARCHITECTURE.md": "deny",
                # opencode.json is the fence config itself. Without this
                # rule the agent can grant itself permissions; with it
                # opencode refuses to write back to its own config from
                # within a session. Paired with .git/info/exclude in
                # clone_fixture, which keeps opencode's own session-
                # state writes from tripping the hypothesis sandbox.
                "opencode.json": "deny",
            },
            "bash": {
                "*": "allow",
                "git checkout main*": "deny",
                "git checkout master*": "deny",
                "git fetch*": "deny",
                "git stash*": "deny",
                "git log -p*": "deny",
                "*cores/baseline*": "deny",
                "*cores/v1*": "deny",
            },
        },
    }
    (clone / "opencode.json").write_text(json.dumps(cfg, indent=2) + "\n")


_CODEX_ISOLATED_CONFIG = """\
# Written by tools/bench/runner.py:isolated_codex_home. A bench agent must
# not inherit the operator's Codex state: memories (which held notes on
# this very benchmark and personal context that then landed in published
# transcripts), plugins (browser / computer-use), MCP servers, skills, or
# project trust entries. Only auth.json is shared, as a symlink.
#
# allow_login_shell = false: with a login shell (`zsh -lc`) the agent's
# PATH is rebuilt from the operator's shell profile, so agents ran
# ~/.local/bin/sby under a python3 without `click` and could not run
# their own formal self-checks, while the orchestrator's gates used the
# runner's PATH. Non-login shells inherit the runner's PATH: agents and
# gates see the same toolchain.
allow_login_shell = false

# No web search (live or OpenAI's cached index): the benchmark's own
# published results are on the web.
web_search = "disabled"

# Features on by default in Codex 0.156 that reach outside the run: the
# ChatGPT account's connected apps and plugins (the V2.1 smoke offered agents
# 201 app tools, 90 of them GitHub, which could read this benchmark's own
# repository), browser and computer use, remote plugin installs. Core tools
# (shell, apply_patch, view_image, subagents) stay on; Claude Code has
# equivalents. research/v2/LEAKS.md.
[features]
memories = false
apps = false
plugins = false
remote_plugin = false
plugin_sharing = false
browser_use = false
browser_use_external = false
browser_use_full_cdp_access = false
computer_use = false
in_app_browser = false
skill_mcp_dependency_install = false
tool_suggest = false

[projects."{clone}"]
trust_level = "trusted"

# Slot worktrees reach riscv-formal through a symlink to the clone's copy,
# which is outside the agent's cwd; without this, Codex agents cannot run
# `make formal` (Claude's sandbox already allows the whole clone). The
# eval's own copy (.tmp/riscv-formal-eval) is not listed.
[sandbox_workspace_write]
writable_roots = ["{clone}/formal/riscv-formal"]
# /tmp is shared by the accounts of concurrent runs. With it writable, Codex
# protects /tmp/.codex and /tmp/.agents by creating them as bubblewrap mount
# targets and removing them afterwards; another account's Codex then fails
# its command ("failed to remove synthetic bubblewrap mount target
# /tmp/.codex: Operation not permitted"), which hit the two Codex runs
# whenever they overlapped. Agents stage scratch files in their private
# TMPDIR (still writable), and Claude's sandbox never allowed /tmp either.
exclude_slash_tmp = true
"""


def _user_codex_home() -> Path:
    return Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")


def isolated_codex_home(clone: Path, user_home: Path | None = None,
                        link_unchecked: bool = False) -> Path:
    """Create <clone>/.codex-home: a CODEX_HOME holding only a minimal
    config.toml and a symlink to the operator's auth.json.

    Not under <clone>/.tmp: the runner sets TMPDIR there, and Codex
    refuses to create its arg0 helper binaries (the `apply_patch` & co.
    PATH aliases) under a temporary dir, which would give bench agents a
    different tool environment than the published reps had.

    auth.json is symlinked, not copied: ChatGPT OAuth refresh tokens
    rotate, and a refresh landing in a copy would leave the operator's
    own login holding a revoked token. sync_codex_auth_back covers the
    case where Codex replaces the symlink with a file.

    link_unchecked: link even though the operator cannot see the target
    (the agent account's own ~/.codex, under HWE_AGENT_USER)."""
    user_home = user_home or _user_codex_home()
    home = clone / ".codex-home"
    if home.exists():
        # Codex leaves 0700 dirs owned by the agent account (tmp/arg0).
        rmtree_shared(home)
    home.mkdir(parents=True)
    auth = user_home / "auth.json"
    if link_unchecked:
        (home / "auth.json").symlink_to(auth)
    elif auth.exists():
        (home / "auth.json").symlink_to(auth.resolve())
    (home / "config.toml").write_text(
        _CODEX_ISOLATED_CONFIG.format(clone=clone.resolve()))
    return home


def sync_codex_auth_back(codex_home: Path, user_home: Path | None = None) -> bool:
    """If Codex rewrote the isolated auth.json as a regular file with a
    newer refresh than the operator's, copy it back. Returns True if it did."""
    user_home = user_home or _user_codex_home()
    return _sync_auth_file(codex_home / "auth.json", user_home / "auth.json")


def _sync_auth_file(iso, real) -> bool:
    import json, os, shutil
    if not iso.exists() or iso.is_symlink():
        return False
    try:
        new = json.loads(iso.read_text()).get("last_refresh") or ""
        old = json.loads(real.read_text()).get("last_refresh") or "" if real.exists() else ""
    except (OSError, ValueError):
        return False
    if new <= old:
        return False
    # The agent accounts share one login through a symlink into a group
    # directory (a copy per account would be revoked by the next refresh's
    # token rotation): write through the link and keep the file's mode.
    real = real.resolve()
    # Never wider than before: owner-only, or owner+group for the shared file.
    shared = real.exists() and real.stat().st_mode & 0o020
    mode = 0o660 if shared else 0o600
    tmp = real.with_name(real.name + ".bench-sync")
    shutil.copy2(iso, tmp)
    os.chmod(tmp, mode)
    os.replace(tmp, real)
    return True


def sync_codex_auth_back_as(agent: AgentUser, codex_home: Path) -> bool:
    """sync_codex_auth_back for the agent account's login, run as it."""
    import inspect
    code = ("from pathlib import Path\nimport sys\n" + inspect.getsource(_sync_auth_file)
            + "\nprint(_sync_auth_file(Path(sys.argv[1]), Path(sys.argv[2])))\n")
    r = as_agent(agent.name, "/usr/bin/python3", "-B", "-c", code,
                 str(codex_home / "auth.json"), str(agent.home / ".codex" / "auth.json"),
                 capture_output=True, text=True)
    return r.stdout.strip() == "True"


def _tool_read_roots(home: Path | None = None) -> list[str]:
    """Install roots of the EDA/compiler binaries, so sandboxed agent
    shells can run them while the rest of $HOME stays unreadable. A root
    that is $HOME or a direct child of it (e.g. ~/.local, from a stray
    wrapper earlier on PATH) is skipped: it would reopen far more than
    the toolchain."""
    from tools.sandbox import EVAL_TOOLS
    home = (home or Path.home()).resolve()
    roots: set[str] = set()
    for tool in EVAL_TOOLS:
        found = shutil.which(tool)
        if not found:
            continue
        for p in (Path(found), Path(found).resolve()):
            root = p.parent.parent.resolve()
            if root == home or root.parent == home:
                continue
            roots.add(str(root))
    return sorted(roots)


def _python_user_site() -> str | None:
    """User site-packages of the python3 on PATH. Test deps (cocotb)
    may be installed there; sandboxed shells need to read it, or Claude
    agents could not run the unit tests Codex agents can."""
    py = shutil.which("python3")
    if not py:
        return None
    try:
        out = subprocess.run([py, "-c", "import site; print(site.getusersitepackages())"],
                             capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    path = out.stdout.strip()
    return path if path and Path(path).is_dir() else None


def claude_isolation_settings(clone: Path, uid: int | None = None,
                              home: Path | None = None,
                              claude_tmp: Path | None = None,
                              read_roots: list[str] | None = None) -> dict:
    """Flag-level settings for bench Claude Code agents (see
    tools/agents/_runtime.py for the CLI flags that go with them).

    Parity with the Codex runs: no web lookup, no operator memory,
    plugins, hooks, MCP servers or claude.ai connectors. Stricter than
    Codex on reads: the Bash sandbox denies all of $HOME and /private/tmp
    except the clone, the toolchain, riscv-formal and Claude's own temp
    dir, and denies every other Claude session's temp subtree (these
    hold other sessions' task outputs, including the operator's). File
    tools are confined to cwd by acceptEdits in -p mode; Read gets
    explicit allows for the same read roots."""
    clone = clone.resolve()
    uid = os.getuid() if uid is None else uid
    home = home or Path.home()
    rf = clone / "formal" / "riscv-formal"
    rf_eval = clone / EVAL_RISCV_FORMAL
    if read_roots is not None:
        # Agent account: toolchain, python user base and CLIs all live in
        # the shared directory.
        reads = [str(clone), *read_roots]
    else:
        reads = [str(clone), *_tool_read_roots(home)]
        user_site = _python_user_site()
        if user_site:
            reads.append(user_site)
        for f in (home / ".gitconfig", home / ".config" / "git"):
            if f.exists():
                reads.append(str(f))
    if rf.exists():
        reads.append(str(rf.resolve()))
    sys_tmp = "/private/tmp" if IS_MAC else "/tmp"
    claude_tmp = claude_tmp or Path(f"{sys_tmp}/claude-{uid}")
    # Claude names each project's temp subtree after its cwd with every
    # non-alphanumeric turned into '-'; the rep's own (clone root and
    # slot worktrees) stay readable.
    own = re.sub(r"[^A-Za-z0-9]", "-", str(clone))
    # Every existing entry, files included: loose scratch files other
    # sessions (or an earlier rep's agents) left at the top level.
    other_sessions = sorted(
        str(p) for p in claude_tmp.glob("*")
        if not p.name.startswith(own)
    ) if claude_tmp.is_dir() else []
    return {
        "disableAllHooks": True,
        "disableClaudeAiConnectors": True,
        "autoMemoryEnabled": False,
        "permissions": {
            "allow": ["Bash", *(f"Read(/{r}/**)" for r in reads)],
            # No web, and nothing that reaches the operator's account or
            # other sessions: ToolSearch is the only way to load Claude
            # Code's deferred tools (cloud triggers, cron, notifications,
            # messaging), the counterpart of Codex's connected apps, which
            # are off too. Core tools and subagents stay, as for Codex.
            "deny": ["WebFetch", "WebSearch", "ToolSearch", "RemoteTrigger", "CronCreate",
                     "CronDelete", "CronList", "PushNotification", "SendMessage",
                     "SendUserFile", "ListAgents", "Monitor"],
        },
        "sandbox": {
            "enabled": True,
            # Refuse to run a command unconfined when the sandbox cannot
            # start; the default (false) runs it without one, silently
            # (V2 incident 06).
            "failIfUnavailable": True,
            "autoAllowBashIfSandboxed": True,
            "allowUnsandboxedCommands": False,
            "filesystem": {
                "allowWrite": [str(clone)],
                # The eval's riscv-formal copy stays harness-only, so no
                # agent self-check can touch the live eval or plant files in
                # it (2026-09-26 incident; see tools/sandbox.py).
                # formal/riscv-formal stays writable for the agents' own
                # formal runs, as it is for Codex.
                "denyWrite": [str(rf_eval)],
                "denyRead": [str(home), sys_tmp, *other_sessions],
                "allowRead": [*reads, str(claude_tmp)],
            },
            "network": {"allowedDomains": []},
        },
    }


def claude_instruction_ancestors(clone: Path) -> list[Path]:
    """CLAUDE.md-style files Claude Code would load from the clone's
    parent directories (it walks up from cwd). A clone under the main
    checkout would pick up the main repo's CLAUDE.md."""
    found = []
    for d in clone.resolve().parents:
        for name in ("CLAUDE.md", "CLAUDE.local.md"):
            if (d / name).is_file():
                found.append(d / name)
    return found


def make_env_for_job(job: JobSpec, clone: Path, keys: dict[str, str]) -> dict[str, str]:
    env = os.environ.copy()
    env["TARGET"] = "bench"
    agent = agent_user()
    if agent:
        env["HWE_AGENT_USER"] = agent.name
        home = run_home(agent, job.slug)
        # Never resume a stale home (a crashed or rerun attempt of this run).
        as_agent(agent.name, "/bin/rm", "-rf", str(home), capture_output=True)
        as_agent(agent.name, "/bin/mkdir", "-p", "-m", "700", str(home), check=True,
                 capture_output=True)
        env["HWE_AGENT_HOME"] = str(home)
        if not IS_MAC:
            tmp = run_tmp(agent, job.slug)
            from tools.eval._subprocess import remove_path
            remove_path(tmp)                    # a crashed or rerun attempt's
            tmp.mkdir(mode=0o700)
            share_with_agent(tmp, agent)
            env["HWE_AGENT_TMP"] = str(tmp)
        cli_dir = model_cli_dir(job.model, agent)
        env["HWE_AGENT_PATH"] = agent.path if cli_dir is None else f"{cli_dir}:{agent.path}"
        env["HWE_AGENT_PYTHONUSERBASE"] = str(agent.local)
        from tools.eval.gowin import GOWIN_HOME
        env["GOWIN_HOME"] = str(GOWIN_HOME)
    if job.model.provider == "codex":
        # Codex CLI: workspace-write sandbox + clone isolation, and an
        # isolated CODEX_HOME (no operator memories/plugins/MCP/skills).
        env["AGENT_PROVIDER"] = "codex"
        env["CODEX_MODEL"] = job.model.model
        if job.model.variant is not None:
            env["CODEX_REASONING_EFFORT"] = job.model.variant
        if agent:
            env["CODEX_HOME"] = str(isolated_codex_home(
                clone, user_home=agent.home / ".codex", link_unchecked=True))
        else:
            env["CODEX_HOME"] = str(isolated_codex_home(clone))
    elif job.model.provider == "opencode":
        # Opencode: per-clone opencode.json permission rules.
        env["AGENT_PROVIDER"] = "opencode"
        env["OPENCODE_MODEL"] = job.model.model
        if job.model.variant is not None:
            env["OPENCODE_VARIANT"] = job.model.variant
    elif job.model.provider == "claude":
        # Claude Code: operator login (Keychain), but no operator
        # settings/plugins/hooks/memory/MCP, and an OS sandbox around
        # Bash. See claude_isolation_settings.
        env["AGENT_PROVIDER"] = "claude"
        env["ANTHROPIC_MODEL"] = job.model.model
        if agent:
            # Login: CLAUDE_CODE_OAUTH_TOKEN (`claude setup-token`) from the
            # keys file; the agent account has no Keychain session.
            roots = agent.read_roots()
            if model_cli_dir(job.model, agent) is not None:
                roots.append(str(model_cli_dir(job.model, agent)))
            settings = claude_isolation_settings(
                clone, uid=agent.uid, home=home, read_roots=roots)
            # The account's real home and the shared auth dir hold the Codex login.
            settings["sandbox"]["filesystem"]["denyRead"] += [
                str(agent.home), str(agent.shared / "auth")]
            if env.get("HWE_AGENT_TMP"):
                fs = settings["sandbox"]["filesystem"]
                fs["allowWrite"].append(env["HWE_AGENT_TMP"])
                fs["allowRead"].append(env["HWE_AGENT_TMP"])
                settings["permissions"]["allow"].append(f"Read(/{env['HWE_AGENT_TMP']}/**)")
            env["CLAUDE_BENCH_SETTINGS"] = json.dumps(settings)
        else:
            env["CLAUDE_BENCH_SETTINGS"] = json.dumps(claude_isolation_settings(clone))
        if job.model.variant is not None:
            env["CLAUDE_EFFORT"] = job.model.variant
        env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        env["DISABLE_TELEMETRY"] = "1"
        env["DISABLE_ERROR_REPORTING"] = "1"
        env["DISABLE_AUTOUPDATER"] = "1"
    elif job.model.provider == "static":
        # No-LLM control runtime. Reads no API key, drives no model.
        env["AGENT_PROVIDER"] = "static"
    elif job.model.provider == "random":
        # Seeded mutation control. Seed = 100 + rep, so reps 1..3 map to
        # the preregistered seeds 101..103 and reruns are reproducible.
        env["AGENT_PROVIDER"] = "random"
        env["RANDOM_AGENT_SEED"] = str(100 + job.rep)
    else:
        raise ValueError(
            f"unsupported provider {job.model.provider!r}; "
            f"expected one of: codex, opencode, claude, static, random"
        )
    # E1c prompt-profile plumbing: the agents' prompt builders read
    # BENCH_PROMPT_PROFILE; only set it for non-default profiles so
    # "full" runs keep an unchanged environment.
    if job.model.prompt_profile != "full":
        env["BENCH_PROMPT_PROFILE"] = job.model.prompt_profile
    # Apply keys from ~/.bench-keys.env, but only for keys not already in env
    # (so a real shell-exported value wins over a file value).
    for k, v in keys.items():
        if not env.get(k):
            env[k] = v
    # The Claude login token belongs to Claude runs only (V2 incident 05: it
    # reached the Codex agents too). Codex reads its own login file.
    if job.model.provider != "claude":
        env.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
    # Host-wide cap on the harness's heavy evals (tools/eval/_slots.py): three
    # concurrent evals, formal at -j6, on the 20-core run host. Not passed to
    # agents (no AGENT_/BENCH_/HWE_ prefix).
    if agent:
        env["HARNESS_EVAL_SLOTS"] = "3"
        env["HARNESS_EVAL_JOBS"] = "6"
        env["HARNESS_EVAL_LOCK_DIR"] = str(Path.home() / ".hwe-eval-slots")
    # For multi-job parallel runs, isolate yosys/nextpnr scratch dirs:
    env["TMPDIR"] = str((clone / ".tmp").resolve())
    Path(env["TMPDIR"]).mkdir(parents=True, exist_ok=True)
    return env


def append_results_row(results_jsonl: Path, row: dict) -> None:
    results_jsonl.parent.mkdir(parents=True, exist_ok=True)
    with results_jsonl.open("a") as f:
        f.write(json.dumps(row, separators=(",", ":")) + "\n")


def run_one_job(job: JobSpec, **kw) -> dict:
    """_run_one_job holding its own agent account for the whole run."""
    agent = acquire_agent()
    try:
        return _run_one_job(job, **kw)
    except Exception as e:
        # Never lose a run without a trace (a harness failure under the
        # incident policy); the clone stays until the rerun re-clones it.
        import traceback
        traceback.print_exc()
        # "harness_error" is not a final status (load_done_set): a restart
        # reruns the run from V0, and both attempts stay on record.
        row = {"model": job.model.name, "rep": job.rep, "status": "harness_error",
               "notes": f"runner exception: {type(e).__name__}: {e}"[:400],
               "ended_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")}
        append_results_row(kw["results_jsonl"], row)
        return row
    finally:
        release_agent(agent, kw["clone_base"] / job.slug)


def _run_one_job(
    job: JobSpec,
    *,
    repo_root: Path,
    ref: str,
    clone_base: Path,
    results_dir: Path,
    results_jsonl: Path,
    keys: dict[str, str],
    n: int,
    k: int,
    timeout_sec: int,
    max_cost_usd: float,
    keep_clone: bool,
) -> dict:
    started = dt.datetime.now(dt.timezone.utc)
    started_iso = started.isoformat(timespec="seconds")
    clone = clone_base / job.slug

    print(f"\n[bench] === {job.slug} starting at {started_iso} ===", flush=True)
    row: dict = {
        "model": job.model.name,
        "rep": job.rep,
        "started_at": started_iso,
        "ended_at": None,
        "wall_clock_sec": None,
        "iterations": 0, "accepted": 0, "rejected": 0, "broken": 0,
        "final_fitness": None, "baseline_fitness": None,
        "best_fitness": None, "best_round": None, "delta_pct": None,
        "total_tokens_in": 0, "total_tokens_out": 0, "total_cost_usd": 0.0,
        "orchestrator_exit": None,
        "status": "failed",
        "notes": "",
    }

    # Forensics dirs/paths computed up front (not just at finalize time)
    # so the early-return paths below (fence install failure, missing
    # API key) can still leave a rep dir behind: without a rep dir,
    # those clones kept no env.json/orchestrator.log forensics AND were
    # invisible to gc's find_stale_clones (which matches clones against
    # existing rep dirs), so they accumulated as orphan clones over a
    # campaign instead of being swept.
    out_dir = results_dir / job.model.name / f"rep{job.rep}"
    fp_path = clone / ".tmp" / "env.json"
    orch_log_path = clone / ".tmp" / "orchestrator.log"

    # Provenance: which eval code (the fixture) and which runner/reporting
    # code produced this row. A dirty runner means the numbers came from
    # code that is in no commit.
    row.update(provenance(repo_root, ref))
    agent = agent_user()
    if agent:
        row["agent_user"] = agent.name
        row.update(agent.cli_versions(model_cli_dir(job.model, agent)))
        if job.model.cli_dir:
            row["cli_dir"] = job.model.cli_dir

    # 1. Fresh clone of the fixture.
    try:
        clone_fixture(repo_root, ref, clone)
    except subprocess.CalledProcessError as e:
        row["notes"] = f"clone failed: {e.stderr.decode() if e.stderr else e}"[:400]
        _finalize(row, started, results_jsonl)
        return row

    # Forensics: snapshot the environment this rep will run under.
    fp_path.parent.mkdir(parents=True, exist_ok=True)
    fp_path.write_text(json.dumps(preflight.env_fingerprint(), indent=2) + "\n")

    # 2. Install per-runtime fencing.
    try:
        if job.model.provider == "opencode":
            install_opencode_config(clone)
        if job.model.provider == "claude":
            inherited = claude_instruction_ancestors(clone)
            if inherited:
                raise RuntimeError(
                    "claude would load instruction files from the clone's "
                    f"parents: {', '.join(map(str, inherited))}; "
                    "use a --clone-base outside any repo")
        # codex uses its workspace-write sandbox + CODEX_HOME; claude gets
        # its sandbox/permission settings through the env (make_env_for_job).
    except Exception as e:
        row["notes"] = f"fence install failed: {e}"[:400]
        _copy_early_forensics(out_dir, fp_path, orch_log_path)
        _finalize(row, started, results_jsonl)
        return row

    # 3. Build env, kick the orchestrator, watchdog the wall-clock + cost.
    env = make_env_for_job(job, clone, keys)
    if not job.model.oauth and job.model.key_env and not env.get(job.model.key_env):
        row["notes"] = f"missing API key env var {job.model.key_env}"
        _copy_early_forensics(out_dir, fp_path, orch_log_path)
        _finalize(row, started, results_jsonl)
        return row

    # 3b. Before any scored work: the agents' commands must run in their
    # sandbox. Not scored and rerunnable (harness_error) when they do not.
    if agent and job.model.provider in ("claude", "codex"):
        probe = run_sandbox_probe(clone, env)
        row["sandbox_probe"] = {k: probe.get(k) for k in ("ok", "reasons", "observed", "attempt")}
        print(f"[bench] {job.slug} sandbox probe: "
              f"{'confined' if probe.get('ok') else 'FAILED ' + '; '.join(probe.get('reasons', []))}",
              flush=True)
        probe_dir = clone / ".tmp" / "sandbox-probe"
        if probe_dir.is_dir():
            out_dir.mkdir(parents=True, exist_ok=True)
            for f in ("verdict.json", "agent.log"):
                if (probe_dir / f).is_file():
                    shutil.copy2(probe_dir / f, out_dir / f"sandbox-probe-{f}")
        if not probe.get("ok"):
            row["status"] = "harness_error"
            row["notes"] = f"sandbox probe failed: {'; '.join(probe.get('reasons', []))}"[:400]
            _copy_early_forensics(out_dir, fp_path, orch_log_path)
            _finalize(row, started, results_jsonl)
            return row

    # Invoke tools.orchestrator directly instead of routing through the
    # Makefile `loop:` rule. The Makefile rule used to assemble exactly
    # this command — N/K/TARGET → --iterations/--tournament-size/--target
    # plus AGENT_PROVIDER from env — so going direct kills a layer of
    # contract drift (every new orchestrator flag would otherwise need a
    # mirror in the Makefile rule too). AGENT_PROVIDER is already set by
    # make_env_for_job in `env`; the orchestrator reads it directly.
    #
    # PWD env var must be updated to the new cwd. subprocess.Popen with
    # cwd= sets the child's actual cwd, but the inherited env's `PWD`
    # still points at the runner's cwd (the main repo). make implicitly
    # exported PWD=<rule cwd> when it ran the orchestrator command, so
    # the bug was invisible through the make middleman. Downstream tools
    # that read $PWD instead of getcwd() — opencode is one — would land
    # in the main repo and write hypothesis YAMLs there instead of into
    # the clone. Caught live during the N=1 K=3 validation: all 3 slots
    # broke as hypothesis_gen_failed because the agent's YAMLs ended up
    # at /Users/.../main-repo/cores/bench/experiments/hypotheses/ instead
    # of the clone's matching path.
    env["PWD"] = str(clone.resolve())
    cmd = [sys.executable, "-m", "tools.orchestrator",
           "--iterations", str(n), "--tournament-size", str(k),
           "--target", "bench"]
    # Stream subprocess stdout+stderr to a per-job log file. Using
    # `stdout=subprocess.PIPE` without a draining thread deadlocks the
    # orchestrator once it fills the OS pipe buffer (~64 KB on macOS),
    # which happens fast on long runs that print summarize_event lines
    # for every pi tool call. A direct file descriptor avoids the issue.
    orch_log_path.parent.mkdir(parents=True, exist_ok=True)
    orch_log = orch_log_path.open("w", buffering=1)
    proc = subprocess.Popen(
        cmd, cwd=str(clone), env=env,
        stdout=orch_log, stderr=subprocess.STDOUT, text=True,
    )

    log_jsonl_path = clone / "cores" / "bench" / "experiments" / "log.jsonl"
    # timeout_sec <= 0 means "no cap" — the runner just waits on the
    # orchestrator. The cost watchdog below is the sole automatic stop
    # in that mode; pass --timeout-sec <N> to re-enable a wall-clock kill.
    has_deadline = timeout_sec > 0
    deadline = time.time() + timeout_sec if has_deadline else None
    cost_check_interval = 60.0
    next_cost_check = time.time() + cost_check_interval
    last_status = "running"

    try:
        while True:
            try:
                rc = proc.wait(timeout=5)
                last_status = "exited"
                row["orchestrator_exit"] = rc
                break
            except subprocess.TimeoutExpired:
                pass
            now = time.time()
            if has_deadline and now >= deadline:
                kill_process_tree(proc.pid)
                last_status = "timed_out"
                row["status"] = "timed_out"
                row["notes"] = f"wall-clock {timeout_sec}s exceeded"
                break
            # OAuth subscription runs are not billed per token, and Claude
            # Code's reported cost is an API-list estimate: no dollar cap.
            if now >= next_cost_check and not job.model.oauth:
                # Peek at the running cost; kill if over budget.
                concat = collect_agent_logs(clone)
                _, _, cost_so_far = parse_cost_from_log(concat, provider=job.model.provider)
                if cost_so_far > max_cost_usd:
                    kill_process_tree(proc.pid)
                    last_status = "over_budget"
                    row["status"] = "failed"
                    row["notes"] = (f"cost {cost_so_far:.2f} > "
                                    f"max {max_cost_usd:.2f}")
                    break
                next_cost_check = now + cost_check_interval
    except KeyboardInterrupt:
        kill_process_tree(proc.pid)
        row["status"] = "failed"
        row["notes"] = "interrupted by user"
        last_status = "interrupted"
    finally:
        try:
            orch_log.close()
        except Exception:
            pass
        agent = agent_user()
        if job.model.provider == "codex" and agent:
            if sync_codex_auth_back_as(agent, clone / ".codex-home"):
                print(f"  [bench] copied a refreshed Codex auth.json back to "
                      f"{agent.name}'s CODEX_HOME", flush=True)
        elif job.model.provider == "codex":
            if sync_codex_auth_back(clone / ".codex-home"):
                print("  [bench] copied a refreshed Codex auth.json back to "
                      "the operator's CODEX_HOME", flush=True)

    # 4. Finalize: collect logs + summary regardless of how we exited.
    out_dir.mkdir(parents=True, exist_ok=True)

    # Reconstruct log.jsonl from the rep clone's git history (commit
    # messages + tree blobs at each `log: hyp-...` commit). This is
    # defense-in-depth against any future bug that causes the on-disk
    # log.jsonl to lose entries — append_log's commits are
    # append-only and persist across HEAD-rewinding bugs. Use the
    # reconstruction whenever it covers more entries than the on-disk
    # file; fall back to the on-disk file otherwise.
    on_disk_lines: list[str] = []
    if log_jsonl_path.is_file():
        on_disk_lines = [
            ln for ln in log_jsonl_path.read_text().splitlines()
            if ln.strip()
        ]
    git_lines = reconstruct_log_from_git(clone, target="bench") or []
    if len(git_lines) > len(on_disk_lines):
        # Print which entries we recovered so it's auditable.
        recovered = len(git_lines) - len(on_disk_lines)
        print(f"  [bench] reconstructed log.jsonl from git: "
              f"{len(git_lines)} entries (vs {len(on_disk_lines)} on disk, "
              f"+{recovered} recovered from orphaned commits)",
              flush=True)
        (out_dir / "log.jsonl").write_text("\n".join(git_lines) + "\n")
    elif log_jsonl_path.is_file():
        shutil.copy2(log_jsonl_path, out_dir / "log.jsonl")

    # Copy orchestrator-emitted run_summary.json if present. summarize_run
    # below prefers this file over re-parsing log.jsonl; copying keeps the
    # rep's results directory self-contained for offline forensics.
    run_summary_src = clone / "cores" / "bench" / "experiments" / "run_summary.json"
    if run_summary_src.is_file():
        shutil.copy2(run_summary_src, out_dir / "run_summary.json")

    # agent.log (tracked) has tool output capped; the verbatim stream is
    # kept as the gitignored agent.full.log.gz. See tools/bench/transcript.py.
    agent_concat = collect_agent_logs(clone)
    if agent_concat.is_file():
        publish_transcript(agent_concat, out_dir)

    # Forensics survive clone deletion: without this, a failed rep's
    # orchestrator.log dies with the clone (the sol rep2/3 startup
    # failures were undiagnosable for exactly this reason).
    if orch_log_path.is_file():
        shutil.copy2(orch_log_path, out_dir / "orchestrator.log")
    if fp_path.is_file():
        shutil.copy2(fp_path, out_dir / "env.json")

    # Cost comes from the verbatim transcript, not the compacted copy.
    summary = summarize_run(out_dir / "log.jsonl",
                            agent_concat if agent_concat.is_file()
                            else out_dir / "agent.log",
                            provider=job.model.provider)
    row.update(summary)
    if job.model.oauth and job.model.provider == "claude":
        # Keep total_cost_usd = billed dollars (0 on a subscription, as
        # for Codex OAuth rows); Claude Code's own list-price estimate
        # goes in its own field.
        row["api_equivalent_cost_usd"] = row.get("total_cost_usd", 0.0)
        row["total_cost_usd"] = 0.0
    if last_status == "exited" and row["orchestrator_exit"] == 0:
        row["status"] = "done"
    elif last_status == "exited":
        row["status"] = "failed"
        row["notes"] = (row["notes"] or "") + (
            f" orchestrator exit={row['orchestrator_exit']}"
            f" (see rep dir orchestrator.log)"
        )

    # Per-rep summary.json
    (out_dir / "summary.json").write_text(json.dumps(row, indent=2) + "\n")

    # Bundle the rep's full git history (accepted diffs, log commits) into
    # the rep dir before the clone is deleted. Makes --keep-clones
    # unnecessary for forensics: the clone itself was only ever needed to
    # inspect commits, and a bundle carries the same history at a few
    # hundred KB-MB instead of a multi-GB working tree (which also drags
    # along the riscv-formal copy).
    #
    # `--all` captures every commit reachable from a ref (branch or tag),
    # not the full object DB: reflog-only orphaned commits (the
    # bench-fixture-v1 rewind class documented in
    # reconstruct_log_from_git's docstring above) are NOT included in
    # this bundle. That class of commit's content survives separately,
    # via the log.jsonl reconstruction that reconstruct_log_from_git runs
    # earlier in this same finalize path, before the clone is deleted.
    bundle = subprocess.run(
        ["git", "bundle", "create", str(out_dir / "repo.bundle"), "--all"],
        cwd=str(clone), capture_output=True)
    if bundle.returncode != 0:
        print(f"  [bench] warn: git bundle failed: "
              f"{bundle.stderr.decode()[:200]}", flush=True)

    # V2: keep the final design readable without the bundle (V1 lost the
    # final RTL of every run that predates bundles).
    save_final_rtl(clone, out_dir)

    # V2 headline metric: the final champion on the held-out kernels, which
    # the agents never see. Scored from the bundle, like tools.bench.transfer.
    if row.get("status") == "done" and bundle.returncode == 0:
        row.update(score_holdout(out_dir))
        (out_dir / "summary.json").write_text(json.dumps(row, indent=2) + "\n")

    _finalize(row, started, results_jsonl)
    if not keep_clone:
        rmtree_shared(clone)

    return row


def save_final_rtl(clone: Path, out_dir: Path) -> None:
    """Copy the final design (git-tracked cores/bench/rtl) to out_dir/final-rtl.

    The accepted design is what git tracks; the working tree also holds
    agent debris, e.g. Claude Code's sandbox writes a 0700 .claude/ dir
    (agent-owned, unreadable to the operator) wherever it works, and copying
    it crashed the finish of a Claude run in the V2.2 smoke."""
    tracked = subprocess.run(
        ["git", "ls-files", "-z", "--", "cores/bench/rtl"],
        cwd=str(clone), capture_output=True, text=True).stdout.split("\0")
    for rel in filter(None, tracked):
        dst = out_dir / "final-rtl" / Path(rel).relative_to("cores/bench/rtl")
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(clone / rel, dst)


def score_holdout(rep_dir: Path) -> dict:
    """Held-out score of a finished rep's champion, as results-row fields.

    Failures are recorded, never raised: a scoring error must not lose the
    rep's other results, and a missing score must not read as zero.
    """
    from tools.bench import transfer
    repo_root = Path(__file__).resolve().parents[2]
    try:
        transfer._build_kernels_once(repo_root)
        scored = transfer.score_rep(rep_dir, repo_root, remeasure=True)
    except Exception as e:  # recorded in the row, see docstring
        return {"holdout_geomean_iter_s": None,
                "holdout_error": f"{type(e).__name__}: {e}"[:500]}
    return {
        "holdout_geomean_iter_s": scored["geomean_iter_s"],
        "holdout_kernels": scored["kernels"],
        "holdout_fmax_mhz": scored["champion_fmax_mhz"],
        "loop_fmax_mhz": scored["loop_fmax_mhz"],
        "holdout_fmax_pairs": scored["final_fmax_pairs"],
    }


def run_sandbox_probe(clone: Path, env: dict, attempts: int = 2) -> dict:
    """The job's agent CLI runs one harness command through its agents'
    exact launch path; the verdict says whether it ran confined
    (tools/agents/sandbox_probe.py). V2 incident 06. A second attempt only
    when the agent did not run the command at all."""
    probe_dir = clone / ".tmp" / "sandbox-probe"
    verdict: dict = {"ok": False, "reasons": ["probe did not run"]}
    for i in range(attempts):
        (probe_dir / "verdict.json").unlink(missing_ok=True)
        r = None
        try:
            r = subprocess.run([sys.executable, "-m", "tools.agents.sandbox_probe", str(probe_dir)],
                               cwd=str(clone), env={**env, "PWD": str(clone.resolve())},
                               capture_output=True, text=True, timeout=900)
            verdict = json.loads((probe_dir / "verdict.json").read_text())
        except (OSError, ValueError, subprocess.TimeoutExpired) as e:
            tail = (r.stderr or "").strip().splitlines()[-1:] if r is not None else []
            verdict = {"ok": False, "reasons": [f"probe error: {type(e).__name__}: {e}", *tail]}
        verdict["attempt"] = i + 1
        if verdict.get("ok") or not any("did not run" in r for r in verdict.get("reasons", [])):
            break
    return verdict


def _copy_early_forensics(out_dir: Path, fp_path: Path, orch_log_path: Path) -> None:
    """Mirror the finalize-block forensics copy for run_one_job's
    early-return paths (fence install failure, missing API key). Those
    exits happen before the normal finalize block runs, so without this
    the clone kept no rep dir at all: no env.json/orchestrator.log for
    post-mortem, and no rep dir for gc's find_stale_clones to key off
    of, so the clone piled up as a gc-invisible orphan.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    if orch_log_path.is_file():
        shutil.copy2(orch_log_path, out_dir / "orchestrator.log")
    if fp_path.is_file():
        shutil.copy2(fp_path, out_dir / "env.json")


def _finalize(row: dict, started: dt.datetime, results_jsonl: Path) -> None:
    ended = dt.datetime.now(dt.timezone.utc)
    row["ended_at"] = ended.isoformat(timespec="seconds")
    row["wall_clock_sec"] = int((ended - started).total_seconds())
    append_results_row(results_jsonl, row)
    print(f"[bench] === {row['model']}-rep{row['rep']} {row['status']} "
          f"in {row['wall_clock_sec']}s, "
          f"fitness={row.get('final_fitness')}, "
          f"cost=${row.get('total_cost_usd', 0):.2f} ===", flush=True)


# ---------- main --------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--models", type=Path, default=DEFAULT_MODELS_YAML)
    ap.add_argument("--ref", default=DEFAULT_REF)
    ap.add_argument("--reps", type=int, default=3, help="J = reps per model")
    ap.add_argument("--n", type=int, default=15, help="N = orchestrator rounds per rep")
    ap.add_argument("--k", type=int, default=3, help="K = parallel hypothesis slots")
    ap.add_argument("--parallel", type=int, default=1,
                    help="run up to N (model, rep) jobs concurrently")
    ap.add_argument("--max-cost", type=float, default=DEFAULT_MAX_COST_USD,
                    help="hard ceiling on $ cost per rep (default $30)")
    ap.add_argument("--timeout-sec", type=int, default=DEFAULT_REP_TIMEOUT_SEC)
    ap.add_argument("--clone-base", type=Path, default=DEFAULT_CLONE_BASE)
    ap.add_argument("--results-dir", type=Path, default=DEFAULT_RESULTS_DIR)
    ap.add_argument("--results-jsonl", type=Path, default=DEFAULT_RESULTS_JSONL)
    ap.add_argument("--keys-file", type=Path,
                    default=Path.home() / ".bench-keys.env")
    ap.add_argument("--only", nargs="+",
                    help="restrict to these model names (e.g. --only opus-47 gpt-5)")
    ap.add_argument("--keep-clones", action="store_true",
                    help="don't delete per-job clones after run (forensics)")
    ap.add_argument("--agent-user", default=os.environ.get("HWE_AGENT_USER") or None,
                    help="run the agent CLIs as this account (V2 isolation; "
                         "see research/v2/scripts/setup_bench_user.sh)")
    ap.add_argument("--interleave", action="store_true",
                    help="run each rep's jobs for all models together, rep by rep "
                         "(V2 schedule; overrides --parallel)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--skip-preflight", action="store_true",
                    help="skip the toolchain pre-flight check (debug only)")
    args = ap.parse_args()

    # `kill <runner>` must not orphan the orchestrators (and their formal /
    # PnR / agent trees). SIGINT is left to the KeyboardInterrupt path in
    # run_one_job, which records the rep as interrupted before tree-killing.
    install_tree_reaper((signal.SIGTERM, signal.SIGHUP))

    if not args.skip_preflight:
        missing = preflight.missing_tools()
        if missing:
            print(f"[bench] FATAL: required tools not on PATH: {missing}",
                  file=sys.stderr)
            print(preflight.report(), file=sys.stderr)
            print("[bench] source setup.sh (or fix PATH) and retry; "
                  "--skip-preflight overrides.", file=sys.stderr)
            return 2
        # Clones land under args.clone_base, which can be a different
        # volume than REPO_ROOT (e.g. via --clone-base pointing at a
        # bigger disk) -- measure free space there, not at REPO_ROOT.
        # clone_base may not exist yet on a fresh override; create it
        # first (clone_fixture would do so anyway for the first job) so
        # os.statvfs has a path to measure. An unwritable parent (e.g. a
        # read-only mount or permission error) must fail the preflight
        # cleanly, not crash with an uncaught OSError traceback.
        try:
            args.clone_base.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            print(f"[bench] FATAL: cannot create clone base "
                  f"{args.clone_base}: {e.strerror or e}", file=sys.stderr)
            print("[bench] pick a writable --clone-base and retry.",
                  file=sys.stderr)
            return 2
        free_gb = preflight.free_disk_gb(str(args.clone_base))
        if free_gb < preflight.MIN_FREE_GB:
            print(f"[bench] FATAL: only {free_gb:.1f} GB free at "
                  f"{args.clone_base} (need >= {preflight.MIN_FREE_GB} GB)",
                  file=sys.stderr)
            print("[bench] free up disk (see `python -m tools.bench.gc`) "
                  "and retry; --skip-preflight overrides.", file=sys.stderr)
            return 2
        print(preflight.report())

    if args.agent_user:
        os.environ["HWE_AGENT_USER"] = args.agent_user
        for a in agent_pool():
            problem = check_agent_user(a)
            if problem:
                print(f"[bench] FATAL: agent user {a.name}: {problem}", file=sys.stderr)
                return 2
        if args.clone_base == DEFAULT_CLONE_BASE:
            args.clone_base = AGENT_SHARED / "clones"
        lock_clone_base(args.clone_base)
        if not IS_MAC:
            lock_clone_base(AGENT_SHARED / "tmp")   # the per-run temp bases (run_tmp)
        for a in agent_pool():
            reset_agent(a)

    models = load_models(args.models)
    keys = load_keyfile(args.keys_file)
    done = load_done_set(args.results_jsonl)
    jobs = enumerate_jobs(models, args.reps, done, only_models=args.only)

    if not jobs:
        print("no jobs to run (all already in results.jsonl). Use --only to override.")
        return 0

    print(f"[bench] {len(jobs)} job(s) queued ({len(done)} already done)")
    for j in jobs:
        print(f"        - {j.slug}  ->  {j.model.provider}:{j.model.model}"
              + (f"  (cli {j.model.cli_dir})" if j.model.cli_dir else ""))
    print(f"[bench] config: N={args.n} K={args.k} reps={args.reps} parallel={args.parallel}")
    print(f"[bench] clone base: {args.clone_base}")
    print(f"[bench] results: {args.results_jsonl}")

    # Validate keys before any expensive operation.
    env_with_keys = {**os.environ, **{k: v for k, v in keys.items() if k not in os.environ}}
    missing = validate_keys(jobs, env_with_keys)
    if args.agent_user and any(j.model.provider == "claude" for j in jobs) \
            and not env_with_keys.get("CLAUDE_CODE_OAUTH_TOKEN"):
        missing.append("CLAUDE_CODE_OAUTH_TOKEN")
    if args.agent_user and any(j.model.provider == "codex" for j in jobs):
        for agent in agent_pool():
            if as_agent(agent.name, "/bin/test", "-s", str(agent.home / ".codex" / "auth.json"),
                        capture_output=True).returncode != 0:
                missing.append(f"Codex login for {agent.name} "
                               f"(sudo -iu {agent.name} {agent.shared}/bin/codex login --device-auth)")
    if missing:
        print(f"[bench] FATAL: missing API key env vars: {missing}", file=sys.stderr)
        print(f"[bench] put them in {args.keys_file} or export in your shell.")
        return 2

    models_used = list({j.model.name: j.model for j in jobs}.values())
    bad_cli = cli_dir_problems(models_used)
    if not args.agent_user:
        bad_cli += [f"{m.name}: cli_dir needs --agent-user" for m in models_used if m.cli_dir]
    if bad_cli:
        print(f"[bench] FATAL: {bad_cli}", file=sys.stderr)
        return 2

    if args.agent_user:
        concurrent = (max(len(b) for b in interleaved_batches(jobs)) if args.interleave
                      else max(1, args.parallel))
        if len(agent_pool()) < concurrent:
            print(f"[bench] FATAL: {concurrent} concurrent runs need as many agent accounts "
                  f"(--agent-user a,b,c); got {len(agent_pool())}. Runs sharing an account "
                  f"can read each other's work.", file=sys.stderr)
            return 2

    if args.dry_run:
        print("[bench] dry-run — exiting without running jobs")
        return 0

    args.results_jsonl.parent.mkdir(parents=True, exist_ok=True)

    failures = 0
    job_kw = dict(repo_root=REPO_ROOT, ref=args.ref, clone_base=args.clone_base,
                  results_dir=args.results_dir, results_jsonl=args.results_jsonl,
                  keys=keys, n=args.n, k=args.k, timeout_sec=args.timeout_sec,
                  max_cost_usd=args.max_cost, keep_clone=args.keep_clones)
    if args.interleave:
        for batch in interleaved_batches(jobs):
            print(f"[bench] batch: {', '.join(j.slug for j in batch)}", flush=True)
            with ThreadPoolExecutor(max_workers=len(batch)) as ex:
                futs = {}
                for j in batch:
                    futs[ex.submit(run_one_job, j, **job_kw)] = j
                    time.sleep(5)   # launch order is the listed order
                for fut in as_completed(futs):
                    try:
                        if fut.result()["status"] != "done":
                            failures += 1
                    except Exception as e:
                        print(f"[bench] {futs[fut].slug}: exception {e}", file=sys.stderr)
                        failures += 1
    elif args.parallel <= 1:
        for j in jobs:
            row = run_one_job(
                j,
                repo_root=REPO_ROOT, ref=args.ref,
                clone_base=args.clone_base,
                results_dir=args.results_dir,
                results_jsonl=args.results_jsonl,
                keys=keys, n=args.n, k=args.k,
                timeout_sec=args.timeout_sec,
                max_cost_usd=args.max_cost,
                keep_clone=args.keep_clones,
            )
            if row["status"] != "done":
                failures += 1
    else:
        with ThreadPoolExecutor(max_workers=args.parallel) as ex:
            futs = {
                ex.submit(
                    run_one_job, j,
                    repo_root=REPO_ROOT, ref=args.ref,
                    clone_base=args.clone_base,
                    results_dir=args.results_dir,
                    results_jsonl=args.results_jsonl,
                    keys=keys, n=args.n, k=args.k,
                    timeout_sec=args.timeout_sec,
                    max_cost_usd=args.max_cost,
                    keep_clone=args.keep_clones,
                ): j
                for j in jobs
            }
            for fut in as_completed(futs):
                try:
                    row = fut.result()
                    if row["status"] != "done":
                        failures += 1
                except Exception as e:
                    j = futs[fut]
                    print(f"[bench] {j.slug}: exception {e}", file=sys.stderr)
                    failures += 1

    print(f"\n[bench] matrix done — {len(jobs) - failures}/{len(jobs)} successful")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
