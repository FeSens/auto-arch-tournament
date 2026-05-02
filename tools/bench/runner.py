"""Bench matrix runner.

Drives the LLM benchmark: enumerates (model, rep) jobs from
tools/bench/models.yaml, clones the bench-fixture-v1 ref into an
isolated per-job directory, copies the bench-fence pi extension into
.pi/extensions/ of the clone, kicks `make N=<N> K=<K> TARGET=bench`
with AGENT_PROVIDER=pi, then summarizes the result and appends a row
to bench/results.jsonl.

Resumable: re-running skips (model, rep) pairs already in results.jsonl.

Usage:
    python -m tools.bench.runner                                  # full matrix
    python -m tools.bench.runner --reps 1 --models opus-47        # subset
    python -m tools.bench.runner --parallel 3 --max-cost 50       # 3 in parallel
    python -m tools.bench.runner --dry-run                        # plan only
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import yaml

from tools.bench.fence_validator import FenceConfig


HERE = Path(__file__).parent
REPO_ROOT = HERE.parent.parent
DEFAULT_MODELS_YAML = HERE / "models.yaml"
DEFAULT_REF = "bench-fixture-v1"
DEFAULT_RESULTS_JSONL = REPO_ROOT / "bench" / "results.jsonl"
DEFAULT_CLONE_BASE = REPO_ROOT / ".claude" / "bench-runs"
DEFAULT_RESULTS_DIR = REPO_ROOT / "bench"
EXTENSION_SRC = HERE / "extensions" / "bench-fence"

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
    pi_model: str
    # API-key environment variable name. For OAuth subscription providers
    # (Codex, Claude Pro, Copilot) the auth lives in ~/.pi/agent/auth.json
    # or ~/.local/share/opencode/auth.json and no env var is needed —
    # set `oauth: true` instead and leave key_env empty.
    key_env: str = ""
    oauth: bool = False
    # Agent runtime to use. "pi" (default for backwards compat with
    # existing model lists), "codex", "opencode", or "claude". When
    # "codex", `pi_model` is the codex --model string (e.g. "gpt-5.5").
    # When "opencode", it's the opencode --model string
    # (e.g. "openai/gpt-5.5", "anthropic/claude-sonnet-4.6").
    provider: str = "pi"


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
            pi_model=m["pi_model"],
            key_env=m.get("key_env", "") or "",
            oauth=bool(m.get("oauth", False)),
            provider=m.get("provider", "pi"),
        ))
    if not out:
        raise ValueError(f"{path}: no models defined")
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
    read credentials from ~/.pi/agent/auth.json — so they're skipped.
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


def clone_fixture(repo_root: Path, ref: str, dest: Path) -> None:
    if dest.exists():
        # Prefer to delete and re-clone for reproducibility — a stale
        # half-built clone is worse than the few seconds spent re-cloning.
        shutil.rmtree(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["git", "clone", "--depth", "1", "--branch", ref, "--single-branch",
         str(repo_root), str(dest)],
        check=True, capture_output=True,
    )
    # CRITICAL: remove any tag with the same name as `ref`. The parent
    # repo can have BOTH a branch named bench-fixture-v1 AND a tag
    # named bench-fixture-v1 (the tag pins the original fixture commit;
    # the branch advances over time). git clone copies both, leaving
    # an ambiguous ref in the clone.
    #
    # Symptom of the ambiguity: `git checkout bench-fixture-v1` in the
    # orchestrator's accept_worktree (tools/worktree.py:_active_branch)
    # silently resolves to the TAG (commit at the fixture freeze point),
    # detaching HEAD and orphaning every log.jsonl commit appended
    # since the bench-runner pre-create. The orchestrator continues
    # producing commits on the detached HEAD, but each subsequent
    # accept_worktree's `git checkout bench-fixture-v1` rewinds again,
    # so the saved log.jsonl ends up containing only the entries
    # appended after the FINAL rewind — observed as "iter=9" / "iter=27"
    # in N=10 K=3 runs that demonstrably executed all 30 slots.
    #
    # Deleting the tag locally in the clone is the surgical fix: it
    # leaves the tag intact in the parent repo (which the user may
    # still rely on) but disambiguates the ref inside the rep clone.
    subprocess.run(
        ["git", "tag", "-d", ref],
        cwd=str(dest), check=False, capture_output=True,
    )
    # The runner copies pi extensions into <clone>/.pi/ and pi writes
    # session state under <clone>/.pi-sessions/. Both must be invisible to
    # the orchestrator's `git status --porcelain` sandbox check
    # (tools/agents/hypothesis.py:_git_offlimits_changes), or the check
    # treats them as untracked off-limits writes and tries to unlink them
    # (which fails on directories with EPERM on macOS). Use git's
    # per-clone exclude file so we don't have to mutate any committed
    # .gitignore.
    exclude_path = dest / ".git" / "info" / "exclude"
    exclude_path.parent.mkdir(parents=True, exist_ok=True)
    extras = (
        "\n# bench runner — keep these out of git status / sandbox\n"
        ".pi/\n.pi-sessions/\n.tmp/\n__pycache__/\n*.pyc\n"
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
    # Pre-create cores/bench/experiments/ as a tracked directory so the
    # orchestrator can `git add` files into it without the sandbox check
    # tripping on the untracked parent dir. The fixture stripped this
    # directory deliberately to keep reps from inheriting each other's
    # state, so we add it back per-clone with a single .gitkeep file.
    exp_dir = dest / "cores" / "bench" / "experiments"
    exp_dir.mkdir(parents=True, exist_ok=True)
    (exp_dir / ".gitkeep").touch()
    subprocess.run(
        ["git", "add", "cores/bench/experiments/.gitkeep"],
        cwd=str(dest), check=True, capture_output=True,
    )
    # commit.gpgsign=false disables any global signing helper (e.g. 1Password
    # ssh-sign) that would prompt interactively or fail non-interactively
    # inside the runner's subprocess. -c overrides the global config for
    # this one command only; the user's global signing setup is untouched.
    subprocess.run(
        ["git", "-c", "user.email=bench-runner@local",
         "-c", "user.name=bench-runner",
         "-c", "commit.gpgsign=false",
         "commit", "--no-gpg-sign",
         "-m", "bench-runner: pre-create experiments dir"],
        cwd=str(dest), check=True, capture_output=True,
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
    # Cost: ~200 MB and ~5-15 s once per rep at clone time. macOS APFS
    # users who want this effectively-free can switch to `cp -Rc`
    # (clonefile(2) — copy-on-write, ~zero extra disk), but the plain
    # `cp -R` form keeps Linux runners portable since GNU coreutils
    # has no `-c` flag.
    rf_src = find_riscv_formal()
    if rf_src is not None:
        rf_dest = dest / "formal" / "riscv-formal"
        rf_dest.parent.mkdir(parents=True, exist_ok=True)
        if not rf_dest.exists():
            subprocess.run(
                ["cp", "-R", str(rf_src.resolve()), str(rf_dest)],
                check=True,
            )


def install_fence(clone: Path) -> None:
    """Copy the bench-fence extension into <clone>/.pi/extensions/ and
    render the per-clone bench-fence.config.json with the absolute clone
    path baked in."""
    target_dir = clone / ".pi" / "extensions" / "bench-fence"
    target_dir.parent.mkdir(parents=True, exist_ok=True)
    if target_dir.exists():
        shutil.rmtree(target_dir)
    shutil.copytree(EXTENSION_SRC, target_dir)

    cfg = FenceConfig(clone_root=str(clone.resolve()))
    cfg.write(target_dir / "bench-fence.config.json")


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


def make_env_for_job(job: JobSpec, clone: Path, keys: dict[str, str]) -> dict[str, str]:
    env = os.environ.copy()
    env["TARGET"] = "bench"
    if job.model.provider == "codex":
        # Codex CLI reference path. Workflow-trained, self-checks
        # reliably — no fence/autofix needed, codex's built-in
        # workspace-write sandbox + clone isolation suffice.
        env["AGENT_PROVIDER"] = "codex"
        env["CODEX_MODEL"] = job.model.pi_model
    elif job.model.provider == "opencode":
        # Opencode is also workflow-trained and self-checks reliably,
        # so no programmatic autofix needed. install_opencode_config
        # writes the per-clone permission deny rules.
        env["AGENT_PROVIDER"] = "opencode"
        env["OPENCODE_MODEL"] = job.model.pi_model
    else:
        # Default: pi runtime.
        env["AGENT_PROVIDER"] = "pi"
        env["PI_MODEL"] = job.model.pi_model
        # PI_SESSION_DIR isolates session storage per-clone WITHOUT
        # relocating auth.json (would defeat OAuth-subscription
        # logins). The pi branch in _runtime.py reads this and
        # forwards it as --session-dir. We deliberately do NOT set
        # PI_CODING_AGENT_DIR, which would override all of
        # ~/.pi/agent/ (including auth.json).
        env["PI_SESSION_DIR"] = str((clone / ".pi-sessions").resolve())
        # Pi-via-OAuth routinely skips the impl prompt's local formal
        # self-check (observed: 0/15 bash invocations across a K=3
        # matrix). BENCH_FORMAL_AUTOFIX=1 tells implement.py to run
        # formal programmatically and re-invoke the agent with the
        # counterexample tail if it fails. Codex/opencode are
        # workflow-trained and self-check naturally — no autofix.
        env["BENCH_FORMAL_AUTOFIX"] = "1"
    # Apply keys from ~/.bench-keys.env, but only for keys not already in env
    # (so a real shell-exported value wins over a file value).
    for k, v in keys.items():
        if not env.get(k):
            env[k] = v
    # For multi-job parallel runs, isolate yosys/nextpnr scratch dirs:
    env["TMPDIR"] = str((clone / ".tmp").resolve())
    Path(env["TMPDIR"]).mkdir(parents=True, exist_ok=True)
    return env


def parse_codex_cost_from_log(log_path: Path) -> tuple[int, int, float]:
    """Sum input/output tokens across a codex --json log.

    Codex emits one event per agent turn:
      {"type":"turn.completed","usage":{"input_tokens":N,
        "cached_input_tokens":N,"output_tokens":N,"reasoning_output_tokens":N}}

    `cached_input_tokens` is a *subset* of `input_tokens` (the prompt
    portion already in the model's KV cache). We sum the gross
    `input_tokens` so the count reflects what the model actually
    processed — callers who want billable-only tokens can subtract
    cache reads via the rate card.

    Cost is always 0.0: codex via OAuth subscription doesn't expose
    per-call billing, and even paid-API codex doesn't emit `cost` in
    its stream-json schema. Apply pricing externally if needed.

    Dedup: collect_agent_logs concatenates the same hypothesis log
    multiple times because both the explicit hypotheses dir AND the
    clone-root rglob pick it up. Without per-line dedup we'd
    double-count every turn. The fix in collect_agent_logs is to use
    a set of paths, but the per-line dedup here is a defensive
    backstop in case any future log path changes re-introduce dupes.
    """
    if not log_path.is_file():
        return (0, 0, 0.0)
    seen: set[str] = set()
    toks_in = toks_out = 0
    for raw in log_path.read_text().splitlines():
        s = raw.strip()
        if not s.startswith("{") or '"turn.completed"' not in s:
            continue
        if s in seen:
            continue
        seen.add(s)
        try:
            ev = json.loads(s)
        except json.JSONDecodeError:
            continue
        if ev.get("type") != "turn.completed":
            continue
        usage = ev.get("usage") or {}
        if not isinstance(usage, dict):
            continue
        try:
            toks_in += int(usage.get("input_tokens") or 0)
            # OpenAI reasoning models report `output_tokens` (visible
            # response + tool-call output) separately from
            # `reasoning_output_tokens` (chain-of-thought, not visible
            # but billed at the output rate). Sum both so the headline
            # output number matches actual model work and matches
            # opencode's normalization (tokens.output + tokens.reasoning).
            toks_out += int(usage.get("output_tokens") or 0)
            toks_out += int(usage.get("reasoning_output_tokens") or 0)
        except (TypeError, ValueError):
            pass
    return (toks_in, toks_out, 0.0)


def parse_opencode_cost_from_log(log_path: Path) -> tuple[int, int, float]:
    """Sum input/output tokens and cost across an opencode --format json log.

    Opencode emits a `step_finish` event after each turn carrying the
    cumulative `tokens` and `cost` for that step:
      {"type":"step_finish", ..., "part":{"tokens":{"input":N,"output":N,
        "reasoning":N,"cache":{"read":N,"write":N}}, "cost":F, ...}}

    `tokens.input` is the *uncached* portion of the prompt; cache hits
    are reported separately under `tokens.cache.read`. To stay
    consistent with parse_codex_cost_from_log (which sums codex's gross
    `input_tokens` per turn — cache included), we count opencode's
    gross input as `tokens.input + tokens.cache.read + tokens.cache.write`.
    Without this normalization an apples-to-apples comparison with
    codex showed a 15× gap that was almost entirely cache-accounting,
    not actual model work — codex's xhigh n10 run reported 16.3M
    "input" of which 14M was cached re-reads of the same prompt;
    opencode at xhigh did the equivalent ~10M (1.1M new + 9.1M cache
    reads) but the saved row read as 1.1M because cache.read was
    skipped. Cumulative effect: the bench underreported opencode's
    token usage by ~10×.

    `cost: 0` is normal under OAuth subscriptions (no per-token
    billing); we still tally token counts regardless.

    cache.write is normally 0 under OpenAI; including it costs nothing
    when 0 and keeps the field semantics correct if a model family
    starts populating it (Anthropic, etc.).
    """
    if not log_path.is_file():
        return (0, 0, 0.0)
    toks_in = toks_out = 0
    cost = 0.0
    for raw in log_path.read_text().splitlines():
        s = raw.strip()
        if not s or not s.startswith("{"):
            continue
        try:
            ev = json.loads(s)
        except json.JSONDecodeError:
            continue
        if ev.get("type") != "step_finish":
            continue
        part = ev.get("part") or {}
        if not isinstance(part, dict):
            continue
        toks = part.get("tokens") or {}
        if isinstance(toks, dict):
            ti = toks.get("input") or 0
            to = toks.get("output") or 0
            cache = toks.get("cache") or {}
            cr = cache.get("read", 0) if isinstance(cache, dict) else 0
            cw = cache.get("write", 0) if isinstance(cache, dict) else 0
            tr = toks.get("reasoning") or 0
            try:
                toks_in += int(ti) + int(cr or 0) + int(cw or 0)
                # Sum visible output + reasoning. opencode reports
                # them separately; both are billed as output. Matches
                # the codex parser, which sums output_tokens +
                # reasoning_output_tokens for the same reason.
                toks_out += int(to) + int(tr or 0)
            except (TypeError, ValueError):
                pass
        c = part.get("cost", 0)
        try:
            cost += float(c or 0)
        except (TypeError, ValueError):
            pass
    return (toks_in, toks_out, cost)


def parse_pi_cost_from_log(log_path: Path) -> tuple[int, int, float]:
    """Sum input_tokens, output_tokens, cost_usd across a pi --mode json log.

    Pi 0.70.6 emits usage data on `message_end`-style events nested under
    `message.usage`. Pre-0.70 it was a top-level `type:"usage"` event.
    We walk both shapes; only the FINAL message of each turn carries the
    authoritative usage (intermediate `message_update` events have
    partial running totals), so we de-duplicate by responseId.
    """
    if not log_path.is_file():
        return (0, 0, 0.0)
    seen_response_ids: set[str] = set()
    toks_in = toks_out = 0
    cost = 0.0

    def _add(usage: dict) -> None:
        nonlocal toks_in, toks_out, cost
        if not isinstance(usage, dict):
            return
        ti = usage.get("input") or usage.get("input_tokens") or usage.get("prompt_tokens") or 0
        to = usage.get("output") or usage.get("output_tokens") or usage.get("completion_tokens") or 0
        c = usage.get("cost")
        if isinstance(c, dict):
            c = c.get("total", 0)
        c = c or usage.get("cost_usd") or 0
        try:
            toks_in += int(ti)
        except (TypeError, ValueError):
            pass
        try:
            toks_out += int(to)
        except (TypeError, ValueError):
            pass
        try:
            cost += float(c)
        except (TypeError, ValueError):
            pass

    for raw in log_path.read_text().splitlines():
        s = raw.strip()
        if not s or not s.startswith("{"):
            continue
        try:
            ev = json.loads(s)
        except json.JSONDecodeError:
            continue
        et = ev.get("type")
        # Pre-0.70 standalone usage event.
        if et == "usage":
            _add(ev)
            continue
        # Pi 0.70.6: a `message_end` (or final assistant_message) carries
        # the authoritative usage. message_update events are partial and
        # would double-count if summed. Use responseId for dedup.
        msg = ev.get("message") if isinstance(ev.get("message"), dict) else None
        if not msg:
            partial = (ev.get("assistantMessageEvent") or {}).get("partial")
            if isinstance(partial, dict):
                msg = partial
        if not isinstance(msg, dict):
            continue
        if msg.get("role") != "assistant":
            continue
        resp = msg.get("responseId")
        # Skip placeholder events: pi emits a message_start with
        # role=assistant, stopReason="stop", and responseId=null/zero
        # usage. Without this guard the parser would dedup on None and
        # silently skip every real terminal event afterward.
        if not resp:
            continue
        if resp in seen_response_ids:
            continue
        usage = msg.get("usage")
        if not isinstance(usage, dict):
            continue
        # Only count when the message has a stopReason (i.e. it's terminal)
        # — partial updates from message_update don't have it set yet.
        if msg.get("stopReason") in (None, ""):
            continue
        # Final guard: skip messages whose usage totals are zero. Pi's
        # placeholder events also have stopReason='stop' AND a non-null
        # responseId in some shapes; the only reliable way to tell a
        # placeholder from a real terminal event is non-zero usage.
        total_toks = (usage.get("totalTokens") or 0) or (
            (usage.get("input") or 0) + (usage.get("output") or 0)
            + (usage.get("input_tokens") or 0) + (usage.get("output_tokens") or 0)
        )
        if not total_toks:
            continue
        seen_response_ids.add(resp)
        _add(usage)
    return (toks_in, toks_out, cost)


def collect_agent_logs(clone: Path) -> Path:
    """Concatenate every per-iteration .agent.*.log into one stream.

    Returns path to the concatenated file (in /tmp); the runner copies
    that into bench/<model>/<rep>/agent.log afterward.
    """
    out_path = clone / ".tmp" / "agent.concatenated.log"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    # Dedup paths: the recursive rglob from `clone` re-finds every
    # .agent*.log under cores/bench/experiments/hypotheses/, so without
    # a set the concat lists each hypothesis log twice. Token parsers
    # also dedup defensively, but fixing it here makes the file shape
    # what the comments describe.
    parts: set[Path] = set()
    for sub in (
        clone / "cores" / "bench" / "experiments" / "hypotheses",
        clone,  # implementation worktrees write .agent.log at root of their dir
    ):
        if sub.is_dir():
            parts.update(sub.rglob(".agent*.log"))
    with out_path.open("w") as outf:
        for p in sorted(parts):
            try:
                outf.write(f"=== {p} ===\n")
                outf.write(p.read_text())
                outf.write("\n")
            except OSError:
                continue
    return out_path


def parse_cost_from_log(log_path: Path, provider: str = "pi") -> tuple[int, int, float]:
    """Dispatch to the right cost parser based on provider."""
    if provider == "opencode":
        return parse_opencode_cost_from_log(log_path)
    if provider == "codex":
        return parse_codex_cost_from_log(log_path)
    return parse_pi_cost_from_log(log_path)


def summarize_run(log_jsonl: Path, agent_log: Path,
                  provider: str = "pi") -> dict:
    """Compute the per-rep summary from an experiments/log.jsonl.

    Schema mirrors the spec's `bench/results.jsonl` row.
    """
    iterations = 0
    accepted = 0
    rejected = 0
    broken = 0
    final_fitness = None
    baseline_fitness = None
    best_round = None
    best_fitness = None

    if log_jsonl.is_file():
        for raw in log_jsonl.read_text().splitlines():
            s = raw.strip()
            if not s:
                continue
            try:
                row = json.loads(s)
            except json.JSONDecodeError:
                continue
            iterations += 1
            outcome = row.get("outcome", "")
            # Orchestrator emits 'improvement' / 'regression' / 'broken'.
            # Older code paths emit 'accepted' / 'rejected' / 'broken'.
            # Map both to a uniform success/failure split so the leaderboard
            # reports correctly.
            if outcome in ("accepted", "improvement"):
                accepted += 1
            elif outcome in ("rejected", "regression"):
                rejected += 1
            elif outcome == "broken":
                broken += 1
            fit = row.get("fitness") or row.get("coremark") or row.get("coremark_iter_s")
            if isinstance(fit, (int, float)):
                if best_fitness is None or fit > best_fitness:
                    best_fitness = float(fit)
                    best_round = iterations
                if outcome in ("accepted", "improvement"):
                    final_fitness = float(fit)
            if baseline_fitness is None:
                bf = row.get("baseline_fitness") or row.get("baseline")
                if isinstance(bf, (int, float)):
                    baseline_fitness = float(bf)

    delta_pct = None
    if final_fitness is not None and baseline_fitness:
        delta_pct = (final_fitness - baseline_fitness) / baseline_fitness * 100.0

    toks_in, toks_out, cost = parse_cost_from_log(agent_log, provider=provider)
    return {
        "iterations": iterations,
        "accepted": accepted,
        "rejected": rejected,
        "broken": broken,
        "final_fitness": final_fitness,
        "baseline_fitness": baseline_fitness,
        "best_fitness": best_fitness,
        "best_round": best_round,
        "delta_pct": delta_pct,
        "total_tokens_in": toks_in,
        "total_tokens_out": toks_out,
        "total_cost_usd": cost,
    }


def append_results_row(results_jsonl: Path, row: dict) -> None:
    results_jsonl.parent.mkdir(parents=True, exist_ok=True)
    with results_jsonl.open("a") as f:
        f.write(json.dumps(row, separators=(",", ":")) + "\n")


def run_one_job(
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

    # 1. Fresh clone of the fixture.
    try:
        clone_fixture(repo_root, ref, clone)
    except subprocess.CalledProcessError as e:
        row["notes"] = f"clone failed: {e.stderr.decode() if e.stderr else e}"[:400]
        _finalize(row, started, results_jsonl)
        return row

    # 2. Install per-runtime fencing.
    try:
        if job.model.provider == "codex":
            # Codex CLI uses its built-in workspace-write sandbox; the
            # standalone clone already removes other cores. No fence
            # file needed.
            pass
        elif job.model.provider == "opencode":
            install_opencode_config(clone)
        else:
            install_fence(clone)
    except Exception as e:
        row["notes"] = f"fence install failed: {e}"[:400]
        _finalize(row, started, results_jsonl)
        return row

    # 3. Build env, kick `make`, watchdog the wall-clock + cost.
    env = make_env_for_job(job, clone, keys)
    if not job.model.oauth and job.model.key_env and not env.get(job.model.key_env):
        row["notes"] = f"missing API key env var {job.model.key_env}"
        _finalize(row, started, results_jsonl)
        return row

    cmd = ["make", f"N={n}", f"K={k}", "TARGET=bench", "loop", "WORKTREE="]
    # Stream subprocess stdout+stderr to a per-job log file. Using
    # `stdout=subprocess.PIPE` without a draining thread deadlocks the
    # orchestrator once it fills the OS pipe buffer (~64 KB on macOS),
    # which happens fast on long runs that print summarize_event lines
    # for every pi tool call. A direct file descriptor avoids the issue.
    orch_log_path = clone / ".tmp" / "orchestrator.log"
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
                proc.kill()
                last_status = "timed_out"
                row["status"] = "timed_out"
                row["notes"] = f"wall-clock {timeout_sec}s exceeded"
                break
            if now >= next_cost_check:
                # Peek at the running cost; kill if over budget.
                concat = collect_agent_logs(clone)
                _, _, cost_so_far = parse_cost_from_log(concat, provider=job.model.provider)
                if cost_so_far > max_cost_usd:
                    proc.kill()
                    last_status = "over_budget"
                    row["status"] = "failed"
                    row["notes"] = (f"cost {cost_so_far:.2f} > "
                                    f"max {max_cost_usd:.2f}")
                    break
                next_cost_check = now + cost_check_interval
    except KeyboardInterrupt:
        proc.kill()
        row["status"] = "failed"
        row["notes"] = "interrupted by user"
        last_status = "interrupted"
    finally:
        try:
            orch_log.close()
        except Exception:
            pass

    # 4. Finalize: collect logs + summary regardless of how we exited.
    out_dir = results_dir / job.model.name / f"rep{job.rep}"
    out_dir.mkdir(parents=True, exist_ok=True)
    if log_jsonl_path.is_file():
        shutil.copy2(log_jsonl_path, out_dir / "log.jsonl")
    agent_concat = collect_agent_logs(clone)
    if agent_concat.is_file():
        shutil.copy2(agent_concat, out_dir / "agent.log")

    summary = summarize_run(out_dir / "log.jsonl", out_dir / "agent.log",
                            provider=job.model.provider)
    row.update(summary)
    if last_status == "exited" and row["orchestrator_exit"] == 0:
        row["status"] = "done"
    elif last_status == "exited":
        row["status"] = "failed"
        row["notes"] = (row["notes"] or "") + f" make exit={row['orchestrator_exit']}"

    # Per-rep summary.json
    (out_dir / "summary.json").write_text(json.dumps(row, indent=2) + "\n")

    _finalize(row, started, results_jsonl)
    if not keep_clone:
        shutil.rmtree(clone, ignore_errors=True)

    return row


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
    ap.add_argument("--n", type=int, default=10, help="N = orchestrator rounds per rep")
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
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    models = load_models(args.models)
    keys = load_keyfile(args.keys_file)
    done = load_done_set(args.results_jsonl)
    jobs = enumerate_jobs(models, args.reps, done, only_models=args.only)

    if not jobs:
        print("no jobs to run (all already in results.jsonl). Use --only to override.")
        return 0

    print(f"[bench] {len(jobs)} job(s) queued ({len(done)} already done)")
    for j in jobs:
        print(f"        - {j.slug}  ->  {j.model.pi_model}")
    print(f"[bench] config: N={args.n} K={args.k} reps={args.reps} parallel={args.parallel}")
    print(f"[bench] clone base: {args.clone_base}")
    print(f"[bench] results: {args.results_jsonl}")

    # Validate keys before any expensive operation.
    env_with_keys = {**os.environ, **{k: v for k, v in keys.items() if k not in os.environ}}
    missing = validate_keys(jobs, env_with_keys)
    if missing:
        print(f"[bench] FATAL: missing API key env vars: {missing}", file=sys.stderr)
        print(f"[bench] put them in {args.keys_file} or export in your shell.")
        return 2

    if args.dry_run:
        print("[bench] dry-run — exiting without running jobs")
        return 0

    args.results_jsonl.parent.mkdir(parents=True, exist_ok=True)

    failures = 0
    if args.parallel <= 1:
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
