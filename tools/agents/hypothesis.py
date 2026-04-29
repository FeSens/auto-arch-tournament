"""Invokes the active agent runtime (codex by default; claude opt-in via
AGENT_PROVIDER) to generate a hypothesis. Writes
experiments/hypotheses/hyp-{id}.yaml.

The agent runs with workspace-write sandbox in the main repo, so this
module brackets the call with a sandbox check: any path it touches
outside experiments/hypotheses/ is reverted and the run is rejected.
Without that, a misbehaving agent could silently patch tools/, schemas/,
etc., and those changes would persist into every subsequent worktree.
"""
import subprocess, json, re, datetime
from pathlib import Path
from tools.agents._runtime import (
    build_agent_cmd,
    run_agent_streaming,
)

def hypotheses_dir(target: str) -> Path:
    """Return per-target hypotheses directory: cores/<target>/experiments/hypotheses."""
    return Path("cores") / target / "experiments" / "hypotheses"


def hypothesis_log(target: str) -> Path:
    return hypotheses_dir(target) / ".agent.log"


# Wall-clock cap on hypothesis generation. Same shape as implement.py's
# CLAUDE_TIMEOUT_SEC. Hypothesis generation reads rtl/ + ARCHITECTURE.md
# + CLAUDE.md + the recent log and proposes one YAML — typically 1-5 min,
# but deeper explorations on later iterations (when easy wins are taken)
# can run longer. 20 min cap.
HYPOTHESIS_TIMEOUT_SEC = 1200


def _hyp_allowed(target: str) -> 're.Pattern':
    """Return allow-list regex scoped to the per-target hypotheses dir."""
    return re.compile(
        rf"^cores/{re.escape(target)}/experiments/hypotheses/[^/]+\.(yaml|yml)$"
    )


def _whitelist_regex(allowed_yaml_ids: list[str], target: str) -> 're.Pattern':
    """Build a regex matching ONLY the round's pre-allocated YAML names.

    Concurrent hypothesis agents share `cores/<target>/experiments/hypotheses/`
    in the main repo. Without a per-round whitelist, slot 0's check would see
    slot 1's YAML as "off-limits" the moment slot 1 finished writing.
    The pre-allocated IDs are the deterministic, finite set of YAMLs the
    round is allowed to produce; anything else is a real breach.
    """
    if not allowed_yaml_ids:
        return _hyp_allowed(target)  # back-compat: any YAML in the per-target dir
    alt = "|".join(re.escape(i) for i in allowed_yaml_ids)
    return re.compile(
        rf"^cores/{re.escape(target)}/experiments/hypotheses/({alt})\.(yaml|yml)$"
    )


def _git_offlimits_changes(allow_re: 're.Pattern') -> list:
    """git status --porcelain in the main repo; flag anything not matching
    the supplied allow regex."""
    out = subprocess.run(
        ["git", "status", "--porcelain"],
        capture_output=True, text=True, check=True,
    ).stdout
    bad = []
    for line in out.splitlines():
        if not line:
            continue
        for p in (s.strip() for s in line[3:].split(" -> ")):
            if p and not allow_re.match(p):
                bad.append(p)
    return bad

def _targets_clause(targets: dict, current_state: dict | None) -> str:
    """Generate the 'Optimization targets' prompt block.

    `targets` is a dict like {"coremark": 300, "lut": 3000}; either key
    may be missing for single-axis mode. `current_state` mirrors the
    same keys with the active branch's champion values.
    """
    from tools.accept_rule import score
    cs = current_state or {}
    ct = targets.get("coremark")
    lt = targets.get("lut")
    cur_perf = cs.get("coremark")
    cur_lut  = cs.get("lut")
    s = score(cur_perf, cur_lut, ct, lt)
    parts = ["## Optimization targets", ""]
    parts.append("This research run targets:")
    if ct is not None:
        parts.append(f"  CoreMark = {ct} iter/s")
    if lt is not None:
        parts.append(f"  LUT4     = {lt}")
    parts.append("")
    parts.append("Current state:")
    if ct is not None and cur_perf is not None:
        status = "target met" if cur_perf >= ct else f"{(ct - cur_perf)/ct*100:.1f}% below target"
        parts.append(f"  CoreMark   = {cur_perf} iter/s   ({status})")
    if lt is not None and cur_lut is not None:
        status = "target met" if cur_lut <= lt else f"{(cur_lut - lt)/lt*100:.1f}% above target"
        parts.append(f"  LUT4       = {cur_lut}           ({status})")
    parts.append(f"  combined score = {s:+.3f}")
    parts.append("")
    if ct is not None and lt is not None:
        parts.append("Accept rule: deficit-driven in phase 1 (any axis below target);")
        parts.append("strict Pareto-dominance in phase 2 (both at target).")
        parts.append("")
        parts.append("Your hypothesis should attack whichever axis is currently failing.")
        parts.append("If both targets are met, find a 'free win' that strictly dominates")
        parts.append("the current design on at least one axis without regressing the other.")
    elif ct is not None:
        parts.append("Accept rule: pull CoreMark toward the target while below; once past")
        parts.append("the target, any CoreMark improvement lands.")
    else:
        parts.append("Accept rule: pull LUT4 toward the target while above; once at/under")
        parts.append("the target, any LUT4 reduction lands.")
    return "\n".join(parts) + "\n\n"


def _build_prompt(log_tail: list, current_fitness: float, baseline_fitness: float,
                  hyp_id: str | None = None,
                  category_hint: str | None = None,
                  targets: dict | None = None,
                  current_state: dict | None = None,
                  target: str | None = None) -> str:
    arch = Path("ARCHITECTURE.md").read_text()
    claude_md = Path("CLAUDE.md").read_text() if Path("CLAUDE.md").exists() else ""
    rtl_dir = Path("cores") / target / "rtl" if target else Path("rtl")
    src_files = sorted(rtl_dir.rglob("*.sv"))
    src_dump  = "\n\n".join(
        f"=== {f} ===\n{f.read_text()}" for f in src_files
    )
    log_str = "\n".join(json.dumps(e) for e in log_tail)

    id_clause = (
        f"Use exactly this hypothesis ID: {hyp_id}\n"
        if hyp_id else
        "The hypothesis ID must follow the format: hyp-YYYYMMDD-NNN\n"
        "where NNN is a zero-padded sequence number based on existing files.\n"
    )
    category_clause = (
        f"Focus this hypothesis on the category: {category_hint}.\n"
        f"This is the diversity slot for this tournament round — pick the\n"
        f"single most promising '{category_hint}' angle, not a hedge across\n"
        f"categories.\n"
        if category_hint else ""
    )
    targets_clause = _targets_clause(targets, current_state) if targets else ""

    philosophy = ""
    if target:
        philo_path = Path("cores") / target / "CORE_PHILOSOPHY.md"
        if philo_path.exists():
            philo_text = philo_path.read_text()
            if philo_text.strip():
                philosophy = (
                    f"## Core philosophy / architect's hard constraints\n"
                    f"{philo_text}\n\n"
                )

    core_yaml_block = ""
    if target:
        yaml_path = Path("cores") / target / "core.yaml"
        if yaml_path.exists():
            core_yaml_block = (
                f"## Core spec (cores/{target}/core.yaml)\n"
                f"```yaml\n{yaml_path.read_text()}```\n\n"
            )

    return f"""You are a CPU microarchitecture research agent.

Your job: propose one architectural hypothesis to improve this RV32IM CPU.
Fitness metric: CoreMark iter/sec = CoreMark iterations/cycle × Fmax_Hz on Tang Nano 20K FPGA.
Current best fitness: {current_fitness:.2f}
Baseline fitness: {baseline_fitness:.2f}

{category_clause}{targets_clause}{philosophy}{core_yaml_block}
## Architecture
{arch}

## Hard invariants (do NOT propose changes that weaken these)
{claude_md}

## Current SystemVerilog Source ({rtl_dir}/)
{src_dump}

## Recent Experiment Log (last 20 entries)
{log_str if log_str else "(no experiments yet — this is the first iteration)"}

## Instructions
1. Analyze the source and experiment log carefully.
2. Identify the most promising architectural improvement.
3. Write a hypothesis YAML file to: cores/{target}/experiments/hypotheses/<id>.yaml

{id_clause}
The YAML must validate against schemas/hypothesis.schema.json:
  id, title, category, motivation, hypothesis, expected_impact, changes

Each `changes[i].file` must be a path under {rtl_dir}/ (this is an SV-source-
of-truth project; do NOT propose Chisel/Scala edits).

Write the file at cores/{target}/experiments/hypotheses/<id>.yaml now. Do not output anything else."""


def _next_id(target: str) -> str:
    hyp_dir = hypotheses_dir(target)
    hyp_dir.mkdir(parents=True, exist_ok=True)
    today = datetime.date.today().strftime("%Y%m%d")
    existing = list(hyp_dir.glob(f"hyp-{today}-*.yaml"))
    n = len(existing) + 1
    return f"hyp-{today}-{n:03d}"


def run_hypothesis_agent(log_tail: list, current_fitness: float,
                         baseline_fitness: float,
                         hyp_id: str | None = None,
                         allowed_yaml_ids: list[str] | None = None,
                         category_hint: str | None = None,
                         targets: dict | None = None,
                         current_state: dict | None = None,
                         target: str | None = None) -> str:
    """Invokes the active agent runtime and returns path to written hypothesis YAML.

    Sandbox: if the agent touches anything outside the round's whitelist
    (default: any YAML in experiments/hypotheses/), revert those changes
    and raise. The orchestrator catches this and logs a 'broken' iteration
    without ever running the eval gates.

    Args:
      log_tail         — recent experiment log entries (last 20).
      current_fitness  — best fitness seen on the current branch.
      baseline_fitness — fitness of the unmodified baseline.
      hyp_id           — pre-allocated ID. Skips _next_id (racy under N>1).
      allowed_yaml_ids — round's full pre-allocated ID list; tightens the
                         sandbox regex so concurrent slots don't flag each
                         other's legitimate YAMLs.
      category_hint    — injected into the prompt; the slot's category per
                         the diversity rotation (micro_opt / structural /
                         predictor / memory / extension).
      targets          — optimization targets dict e.g. {"coremark": 300}.
      current_state    — current champion values mirroring `targets` keys.
      target           — core name under cores/; required. Writes hypothesis
                         YAMLs to cores/<target>/experiments/hypotheses/.
    """
    if target is None:
        raise ValueError("run_hypothesis_agent: target is required (multi-core layout)")
    if hyp_id is None:
        hyp_id = _next_id(target)
    prompt = _build_prompt(log_tail, current_fitness, baseline_fitness,
                           hyp_id=hyp_id, category_hint=category_hint,
                           targets=targets, current_state=current_state,
                           target=target)
    allow_re = _whitelist_regex(allowed_yaml_ids or [], target)

    # Stream agent output to cores/<target>/experiments/hypotheses/.agent.{hyp_id}.log
    # (or .agent.log for the legacy single-slot path) so Phase 1 progress
    # is observable via `tail -f`. Without streaming, the agent's wall-clock
    # makes hypothesis generation look frozen for ~5-10 minutes while it
    # reads the full rtl/, ARCHITECTURE.md, CLAUDE.md, and the experiment
    # log. The per-slot path is gitignored by the `.agent.*.log` /
    # `.agent.*.last` rules so it does not trip the sandbox check below.
    hyp_dir = hypotheses_dir(target)
    hyp_dir.mkdir(parents=True, exist_ok=True)
    # Codex needs an output-last-message file; claude ignores it.
    last_msg = hyp_dir / f".agent.{hyp_id}.last" if hyp_id else hyp_dir / ".agent.last"
    # Per-slot log path so concurrent N>1 slots don't interleave streams in
    # the shared `.agent.log`. Falls back to the per-target hypothesis_log()
    # for the legacy single-slot path.
    hyp_log_path = (hyp_dir / f".agent.{hyp_id}.log") if hyp_id else hypothesis_log(target)
    cmd = build_agent_cmd(
        prompt, cwd=".",
        output_last_message=last_msg,
        enable_search=False,  # prompt has no search instruction; enable when added
    )
    rc, timed_out = run_agent_streaming(
        cmd, cwd=".", log_path=hyp_log_path, timeout_sec=HYPOTHESIS_TIMEOUT_SEC,
    )
    if rc != 0 and not timed_out:
        # Single retry. Append (not truncate) so the first attempt's stream
        # — often the actual rate-limit/error evidence we want to debug —
        # is preserved alongside the retry's.
        print(f"  [agent] non-zero exit ({rc}); retrying once", flush=True)
        with hyp_log_path.open("a") as log:
            log.write(f'\n{{"type":"retry_marker","first_rc":{rc}}}\n')
        rc, timed_out = run_agent_streaming(
            cmd, cwd=".", log_path=hyp_log_path, timeout_sec=HYPOTHESIS_TIMEOUT_SEC,
            mode="a",
        )

    if timed_out:
        print(f"  [agent] TIMEOUT after {HYPOTHESIS_TIMEOUT_SEC}s — process killed",
              flush=True)
    elif rc != 0:
        raise subprocess.CalledProcessError(rc, cmd)

    breaches = _git_offlimits_changes(allow_re)
    if breaches:
        # Hard-revert anything the agent touched outside its allow list.
        # `git checkout HEAD --` restores tracked files; new files have to
        # be removed by hand.
        for p in breaches:
            subprocess.run(["git", "checkout", "HEAD", "--", p],
                           capture_output=True)
            path = Path(p)
            if path.exists() and p not in [
                line.split()[-1] for line in subprocess.run(
                    ["git", "ls-files"],
                    capture_output=True, text=True).stdout.splitlines()
            ]:
                path.unlink(missing_ok=True)
        raise PermissionError(
            f"Hypothesis agent modified off-limits paths and was rolled back: {breaches}"
        )

    path = hyp_dir / f"{hyp_id}.yaml"
    if not path.exists():
        # Agent may have written under a slightly different name (e.g. a
        # ".v2" suffix). Accept ONLY files whose name starts with this
        # slot's hyp_id prefix — never a sibling slot's YAML, which under
        # concurrent N>1 execution would silently swap one slot's output
        # for another's. allowed_yaml_ids stays the input to the SANDBOX
        # check (sibling YAMLs may legitimately appear during a concurrent
        # write); it is NOT the right input to a path resolver.
        prefix = hyp_id
        candidates = sorted(
            hyp_dir.glob(f"{prefix}*.yaml"),
            key=lambda f: f.stat().st_mtime,
        )
        if candidates:
            path = candidates[-1]
        elif not allowed_yaml_ids:
            # Truly-legacy single-slot caller (no pre-allocated ID set).
            # Original "newest in dir" fallback is safe here because there
            # is only one agent in flight.
            files = sorted(hyp_dir.glob("hyp-*.yaml"),
                           key=lambda f: f.stat().st_mtime)
            if files:
                path = files[-1]
            else:
                raise FileNotFoundError("Hypothesis agent did not write a hypothesis file.")
        else:
            # Tournament mode: agent wrote nothing matching this slot's
            # prefix. Bail loudly rather than guess from sibling YAMLs.
            raise FileNotFoundError(
                f"Hypothesis agent did not write a file for slot {hyp_id} "
                f"(allowed_yaml_ids={allowed_yaml_ids})"
            )
    return str(path)
