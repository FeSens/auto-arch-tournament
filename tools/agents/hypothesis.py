"""Invokes the active agent runtime (codex by default; claude opt-in via
AGENT_PROVIDER) to generate a hypothesis. Writes
experiments/hypotheses/hyp-{id}.yaml.

The agent runs in its own disposable git worktree of the champion (edits
there are discarded; its YAML is copied out). The main clone is still
bracketed by a sandbox check: any path the agent touches there outside
experiments/hypotheses/ is reverted and the run is rejected. Without that,
a misbehaving agent could silently patch tools/, schemas/, etc., and those
changes would persist into every subsequent worktree.
"""
import subprocess, re, datetime, os
import yaml
from pathlib import Path
from tools.agents._runtime import (
    build_agent_cmd,
    run_agent_streaming,
)

def hypotheses_dir(target: str) -> Path:
    """Return per-target hypotheses directory as an absolute path.

    Absolute via `.resolve()` so concurrent slot threads, agent
    subprocesses, and any code path that briefly changes cwd all
    converge on the same on-disk location. The relative form
    surfaced as `[Errno 1] Operation not permitted: 'experiments'`
    on bench reps where the leaf component bubbled up alone.
    """
    return (Path.cwd() / "cores" / target / "experiments" / "hypotheses").resolve()


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


def _git_offlimits_changes(allow_re: 're.Pattern', before: dict | None = None) -> list:
    """Main-repo paths whose dirty state changed since `before` (a
    tools.sandbox.dirty_state() snapshot) and that don't match the allow
    regex. Pre-existing dirt is not the agent's doing and is ignored."""
    from tools.sandbox import changed_since, dirty_state
    return changed_since(before or {}, dirty_state("."), allow_re.match)

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


def _recent_outcomes(log_tail: list, n: int = 5) -> str:
    """One-line summary per recent log entry; n most recent.

    Replaces the previous full-JSONL inlining (which made the prompt grow
    linearly with iteration count). For deeper context the agent is expected
    to Read/Grep cores/<target>/experiments/log.jsonl directly.
    """
    entries = log_tail[-n:] if log_tail else []
    if not entries:
        return "(no experiments yet — this is the first iteration)"
    lines = []
    for e in entries:
        delta = e.get('delta_pct')
        delta_s = f"{delta:+.2f}%" if isinstance(delta, (int, float)) else "    n/a"
        title = (e.get('title') or '')[:60]
        lines.append(
            f"  - {e.get('id','?'):28s}  {e.get('outcome','?'):16s}  "
            f"Δ={delta_s:>8s}  {title}"
        )
        cp = e.get('critical_path')
        if isinstance(cp, dict) and e.get('fmax_mhz'):
            lines.append(
                f"      Fmax {e['fmax_mhz']} MHz; worst path {cp.get('arrival_ns')} ns, "
                f"{cp.get('logic_cells')} cells: {' > '.join(cp.get('modules') or [])}")
    return "\n".join(lines)


# Soft cap on inlined LESSONS.md: beyond this many lines we switch to a
# pointer-only block so the prompt stays manageable. Tuned conservatively;
# at ~60% scribe-write × 4 slots × ~50 rounds = 120 lines, plenty of room.
_LESSONS_INLINE_MAX_LINES = 200


def _lessons_block(target: str | None) -> str:
    """Return LESSONS.md inline if small, a pointer otherwise."""
    if not target:
        return "(no target — lessons unavailable)"
    p = Path("cores") / target / "LESSONS.md"
    if not p.exists():
        return "(no lessons recorded yet — file does not exist)"
    text = p.read_text()
    nl = text.count("\n")
    if nl > _LESSONS_INLINE_MAX_LINES:
        return (f"(LESSONS.md is large — {nl} lines. Read it directly: "
                f"`Read cores/{target}/LESSONS.md` or grep for relevant terms.)")
    return text.rstrip() if text.strip() else "(file is empty)"


def _build_prompt(log_tail: list, current_fitness: float, baseline_fitness: float,
                  hyp_id: str | None = None,
                  category_hint: str | None = None,
                  targets: dict | None = None,
                  current_state: dict | None = None,
                  target: str | None = None) -> str:
    # E1c attribution control: BENCH_PROMPT_PROFILE=naive strips all
    # optimization scaffolding (fitness numbers, targets clause,
    # ARCHITECTURE.md, CORE_PHILOSOPHY.md, recent outcomes, lessons)
    # while keeping the mechanical contract (pre-allocated id, slot
    # category, schema block, write fence, source dump, hard
    # invariants) byte-identical to the full profile. static_agent and
    # random_agent sniff the retained schema/write-fence strings to
    # detect the phase; the orchestrator whitelist keys off the id.
    naive = os.environ.get("BENCH_PROMPT_PROFILE", "full") == "naive"
    arch = Path("ARCHITECTURE.md").read_text()
    claude_md = Path("CLAUDE.md").read_text() if Path("CLAUDE.md").exists() else ""
    rtl_dir = Path("cores") / target / "rtl" if target else Path("rtl")
    src_files = sorted(rtl_dir.rglob("*.sv"))
    src_dump  = "\n\n".join(
        f"=== {f} ===\n{f.read_text()}" for f in src_files
    )
    recent_outcomes_str = _recent_outcomes(log_tail, n=5)

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
    targets_clause = _targets_clause(targets, current_state) if (targets and not naive) else ""

    philosophy = ""
    if target and not naive:
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
            if naive:
                # core.yaml carries targets:/current: fitness blocks,
                # which are exactly the optimization scaffold the naive
                # profile strips. Keep only the mechanical contract keys
                # (RVFI port shape via nret, ISA, FPGA target) inside
                # the same block header. Missing or unparseable files
                # degrade to no block, mirroring the full profile's
                # missing-file behavior.
                try:
                    spec = yaml.safe_load(yaml_path.read_text())
                except yaml.YAMLError:
                    spec = None
                contract = {
                    k: spec[k]
                    for k in ("name", "isa", "nret", "target_fpga")
                    if isinstance(spec, dict) and k in spec
                }
                if contract:
                    dumped = yaml.safe_dump(
                        contract, default_flow_style=False, sort_keys=False)
                    core_yaml_block = (
                        f"## Core spec (cores/{target}/core.yaml)\n"
                        f"```yaml\n{dumped}```\n\n"
                    )
            else:
                core_yaml_block = (
                    f"## Core spec (cores/{target}/core.yaml)\n"
                    f"```yaml\n{yaml_path.read_text()}```\n\n"
                )

    target_banner = ""
    if target:
        target_banner = f"""## ⚠️  TARGET CORE: cores/{target}/

You are proposing a hypothesis for **cores/{target}/** ONLY.

In your hypothesis YAML, write `changes[i].file` as `rtl/<filename>`
(or `test/test_<name>.py`) — the SHORT form, RELATIVE to the rtl
directory. The orchestrator resolves these against cores/{target}/rtl/
when it runs the implementation phase. Do NOT write the long form
`cores/{target}/rtl/<filename>` in changes[i].file — the schema's
regex rejects it.

"""

    fitness_lines = "" if naive else (
        f"Current best fitness: {current_fitness:.2f}\n"
        f"Baseline fitness: {baseline_fitness:.2f}\n"
    )
    arch_section = "" if naive else f"\n## Architecture\n{arch}\n"
    history_section = "" if naive else f"""

## Recent outcomes (last 5)
{recent_outcomes_str}

## Distilled lessons from prior iterations (cores/{target}/LESSONS.md)
{_lessons_block(target)}

## How to dig deeper
- Full per-iteration history is at: cores/{target}/experiments/log.jsonl
  Each line is one experiment: hypothesis prose + fitness numbers + outcome
  + the implementing agent's implementation_notes. Use Read or Grep to dig
  into specific past hypotheses by id, category, outcome, or content.
- LESSONS.md (above) is the curated, append-only log of one-line takeaways.
  Read it before proposing — it captures negative knowledge (what failed
  and why) you would otherwise re-discover."""
    lessons_instruction = "" if naive else (
        "1. Read LESSONS.md and the recent outcomes above. Grep log.jsonl for\n"
        "   relevant prior attempts in the same category before proposing.\n"
    )

    budget_min = HYPOTHESIS_TIMEOUT_SEC // 60
    time_clause = f"""## Time budget
You have {budget_min} minutes of wall-clock time. At the limit your process is
killed. A hypothesis file already written at that moment is still used;
no file means this attempt is lost.
- Within your first 5 minutes, write a complete, schema-valid YAML at the
  path below, even if you intend to refine it.
- Refine by overwriting that same file.
- Run experiments (simulation, place-and-route) only if they fit in the
  remaining time. Timing comes from the FPGA vendor's tool (Gowin EDA):
  `make timing TARGET=<core>` prints the Fmax the evaluator scores and the
  worst paths, and takes a few minutes; the evaluator measures timing for
  you after implementation.

"""

    from tools.accept_rule import ACCEPT_MARGIN_LN, margin_pct
    margin_clause = (
        f"Acceptance: a candidate replaces the champion only if its score is more\n"
        f"than {margin_pct():.1f}% above the champion's. Changes that do not alter the\n"
        f"circuit still move place-and-route results by several percent, so\n"
        f"smaller expected gains will not be accepted.\n\n"
        if ACCEPT_MARGIN_LN > 0 else ""
    )

    return f"""You are a CPU microarchitecture research agent.

Your job: propose one architectural hypothesis to improve this RV32IM CPU.
Fitness metric: CoreMark iter/sec = CoreMark iterations/cycle × Fmax_Hz on Tang Nano 20K FPGA.
{fitness_lines}
{target_banner}{category_clause}{targets_clause}{philosophy}{core_yaml_block}{arch_section}
## Hard invariants (do NOT propose changes that weaken these)
{claude_md}

## Current SystemVerilog Source ({rtl_dir}/)
{src_dump}{history_section}

{time_clause}{margin_clause}## Instructions
{lessons_instruction}2. Identify the most promising architectural improvement.
3. Use the **write** tool to write a hypothesis YAML file at:
     cores/{target}/experiments/hypotheses/<id>.yaml
   Do NOT output the YAML as text in your reply — the orchestrator only
   sees files written via the write tool.

{id_clause}

## Required YAML structure (validates against schemas/hypothesis.schema.json)

```yaml
id: hyp-YYYYMMDD-NNN-rRsS         # exactly the ID above
title: "Short description ≥5 chars"
category: micro_opt                # one of: micro_opt | structural | extension | predictor | memory
motivation: |
  Why this matters — a few sentences. Minimum 20 chars.
hypothesis: |
  What you propose to change and why it should help. Minimum 20 chars.
expected_impact:
  fitness_delta_pct: 5             # INTEGER (-50..+50). Schema rejects strings.
  confidence: medium                # exactly one of: low | medium | high. Schema rejects anything else.
changes:                            # at least one entry
  - file: rtl/forward_unit.sv      # IMPORTANT: relative to rtl/, no `cores/<target>/` prefix.
    description: "What you'll change in this file."
  - file: rtl/id_stage.sv          # Or `test/test_<name>.py` for cocotb suites.
    description: "..."
```

### Common mistakes that make schemas reject the file (do NOT do these)

- `expected_impact: "free-text description"` — schema requires an OBJECT with `fitness_delta_pct` (integer) and `confidence` (enum). Strings are rejected.
- `expected_impact: {{fitness_delta_pct: 5.0, confidence: "Med"}}` — `fitness_delta_pct` must be a Python integer (not float, not "5"); `confidence` must be lowercase `low`/`medium`/`high`.
- `changes[i].file: cores/{target}/rtl/alu.sv` — schema's regex requires the `rtl/...` form. Drop the `cores/<target>/` prefix.
- `changes[i].file: alu.sv` — the regex requires the `rtl/` prefix.
- Writing the YAML inline in your message instead of using the write tool.

Use the write tool now."""


_FILE_PATH_RE = re.compile(r"^cores/[^/]+/(rtl/.+|test/test_[^/]+\.py)$")


def normalize_hypothesis_yaml(path: Path, target: str) -> bool:
    """Best-effort fix-ups on a hypothesis YAML so it matches the schema.

    Mutates the file in place; returns True if any change was made. The
    schema's `changes[].file` regex only accepts `rtl/...` and
    `test/test_*.py`, but a model that follows the prompt loosely may
    emit the longer `cores/<target>/rtl/foo.sv` form. We strip the
    `cores/<target>/` prefix so validation succeeds.

    Also repairs a small set of common LLM-emitted YAML artifacts:
      - trailing stray closing braces (`}`) at the very end of the file
        from a model accidentally mixing block + flow style
      - trailing stray brackets (`]`) likewise

    We deliberately do NOT coerce `expected_impact` or any other field —
    those failures are real model-behavior signal that the benchmark
    should record, not paper over.
    """
    if not path.is_file():
        return False
    raw = path.read_text()
    try:
        data = yaml.safe_load(raw)
    except yaml.YAMLError:
        # Try cheap repairs before giving up.
        repaired = raw
        # Strip a stray trailing `}` or `]` at end-of-file (after possible
        # whitespace) — a common artifact of models mixing block/flow style.
        for _ in range(4):
            stripped = repaired.rstrip()
            if stripped and stripped[-1] in "}]" and not stripped.endswith("}}") and not stripped.endswith("]]"):
                repaired = stripped[:-1].rstrip() + "\n"
                continue
            break
        try:
            data = yaml.safe_load(repaired)
        except yaml.YAMLError:
            return False
        if isinstance(data, dict):
            path.write_text(repaired)
            raw = repaired
        else:
            return False
    if not isinstance(data, dict):
        return False
    changed = False
    prefix = f"cores/{target}/"
    for c in (data.get("changes") or []):
        if not isinstance(c, dict):
            continue
        f = c.get("file")
        if not isinstance(f, str):
            continue
        if f.startswith(prefix):
            new_f = f[len(prefix):]
            if _FILE_PATH_RE.match(f) or new_f.startswith(("rtl/", "test/test_")):
                c["file"] = new_f
                changed = True
    if changed:
        path.write_text(yaml.safe_dump(data, sort_keys=False))
    return changed


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
    # Each hypothesis agent works in its own disposable worktree of the
    # champion, not in the shared clone root (harness 2.3, incident 02).
    # With a shared tree, one agent's in-place trial edit (reverted before
    # it finished) was caught by a sibling's before/after check, which
    # blamed and rolled back the sibling, and siblings read non-champion
    # RTL meanwhile. Now an agent's edits stay in its own workspace and are
    # discarded with it; only its YAML is copied to the round's directory.
    import shutil
    from tools.worktree import create_worktree, destroy_worktree
    from tools.sandbox import changed_since, dirty_state, revert_paths
    ws_id = f"{hyp_id}-hypgen"
    ws = Path(create_worktree(ws_id, base_branch="HEAD", target=target))
    ws_hyp_dir = ws / "cores" / target / "experiments" / "hypotheses"
    ws_hyp_dir.mkdir(parents=True, exist_ok=True)
    cmd = build_agent_cmd(
        prompt, cwd=str(ws),
        output_last_message=last_msg,
        enable_search=False,  # prompt has no search instruction; enable when added
    )
    # The main clone must stay untouched (an agent could still write there
    # by absolute path): checked as before.
    before = dirty_state(".")
    from tools.agents.quota import run_with_quota_wait

    def _discard_partial_hypothesis() -> None:
        # A provider limit interrupted this attempt: rerun it from scratch.
        for d in (hyp_dir, ws_hyp_dir):
            for f in d.glob(f"{hyp_id}*.yaml"):
                f.unlink(missing_ok=True)

    def _run(mode: str) -> tuple[int, bool]:
        return run_agent_streaming(cmd, cwd=str(ws), log_path=hyp_log_path,
                                   timeout_sec=HYPOTHESIS_TIMEOUT_SEC, mode=mode)

    try:
        rc, timed_out = run_with_quota_wait(_run, hyp_log_path, _discard_partial_hypothesis)
        if rc != 0 and not timed_out:
            # Single retry. Append (not truncate) so the first attempt's stream
            # — often the actual rate-limit/error evidence we want to debug —
            # is preserved alongside the retry's.
            print(f"  [agent] non-zero exit ({rc}); retrying once", flush=True)
            with hyp_log_path.open("a") as log:
                log.write(f'\n{{"type":"retry_marker","first_rc":{rc}}}\n')
            rc, timed_out = run_with_quota_wait(_run, hyp_log_path, _discard_partial_hypothesis,
                                                initial_mode="a")

        if timed_out:
            print(f"  [agent] TIMEOUT after {HYPOTHESIS_TIMEOUT_SEC}s — process killed",
                  flush=True)
        elif rc != 0:
            raise subprocess.CalledProcessError(rc, cmd)

        # Leftover edits in the agent's own workspace (trial experiments) are
        # discarded with it and cost nothing; they are only reported.
        leftovers = changed_since({}, dirty_state(ws),
                                  lambda p: p.startswith(f"cores/{target}/experiments/hypotheses/"))
        if leftovers:
            print(f"  [agent] {hyp_id}: discarding workspace edits {leftovers[:6]}", flush=True)
        for f in ws_hyp_dir.glob(f"{hyp_id}*.y*ml"):
            shutil.copy2(f, hyp_dir / f.name)
    finally:
        destroy_worktree(ws_id, target)

    breaches = _git_offlimits_changes(allow_re, before)
    if breaches:
        # Hard-revert anything the agent touched outside its allow list
        # (tools.sandbox.revert_paths: tracked -> HEAD, new -> deleted,
        # pre-existing dirt left alone).
        #
        # NEVER revert the log.jsonl path — it's the orchestrator's own
        # journal. If an agent's tool somehow leaves a touch-mark on it
        # (file mtime change, no-content-diff write), the breach check
        # picks it up and `git checkout HEAD -- log.jsonl` would throw
        # away in-flight append_log writes, leaving the saved log
        # truncated to whatever the previous commit was. Observed on
        # N=10 K=3 runs where the saved log lost rounds 1-8 entries.
        # Keep the breach reported (the agent shouldn't be touching it)
        # but don't physically restore the file.
        revert_paths([p for p in breaches
                      if not (p.endswith("/log.jsonl") or p == "log.jsonl")],
                     before)
        raise PermissionError(
            f"Hypothesis agent modified off-limits paths and was rolled back: {breaches}"
        )

    path = hyp_dir / f"{hyp_id}.yaml"
    if path.exists():
        try:
            normalize_hypothesis_yaml(path, target)
        except Exception:
            # Normalization is best-effort; let the schema validator
            # report the failure if the YAML is genuinely malformed.
            pass
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
            try:
                normalize_hypothesis_yaml(path, target)
            except Exception:
                pass
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
