"""Invokes claude -p to generate a hypothesis. Writes experiments/hypotheses/hyp-{id}.yaml.

The agent runs with --dangerously-skip-permissions in the main repo, so
this module brackets the call with a sandbox check: any path it touches
outside experiments/hypotheses/ is reverted and the run is rejected.
Without that, a misbehaving hypothesis agent could silently patch tools/,
schemas/, etc., and those changes would persist into every subsequent
worktree.
"""
import subprocess, json, re, datetime, hashlib
from pathlib import Path

HYPOTHESES_DIR = Path("experiments/hypotheses")
HYPOTHESIS_LOG = HYPOTHESES_DIR / ".claude.log"


def _summarize_event(line: str) -> str | None:
    """Best-effort one-liner from a stream-json NDJSON event.

    Mirror of tools/agents/implement.py:_summarize_event — same shape,
    duplicated so neither module needs to import a private symbol from
    the other. Failures must NOT raise; .claude.log is authoritative.
    """
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        return None
    if ev.get('type') != 'assistant':
        return None
    for c in ev.get('message', {}).get('content', []) or []:
        if not isinstance(c, dict):
            continue
        if c.get('type') == 'tool_use':
            inp = c.get('input') or {}
            target = (inp.get('file_path')
                      or inp.get('command')
                      or inp.get('description')
                      or inp.get('pattern')
                      or '')
            if isinstance(target, str) and len(target) > 80:
                target = target[:77] + '...'
            return f"{c.get('name', '?')}: {target}".rstrip(': ').strip()
    return None

# Same allow-list spirit as orchestrator.path_is_allowed but scoped to the
# hypothesis-agent's job: it should ONLY add a YAML in experiments/hypotheses/.
HYP_ALLOWED = re.compile(r"^experiments/hypotheses/[^/]+\.(yaml|yml)$")


def _git_offlimits_changes() -> list:
    """git status --porcelain in the main repo; flag anything not matching
    the hypothesis-agent allow list."""
    out = subprocess.run(
        ["git", "status", "--porcelain"],
        capture_output=True, text=True, check=True,
    ).stdout
    bad = []
    for line in out.splitlines():
        if not line:
            continue
        for p in (s.strip() for s in line[3:].split(" -> ")):
            if p and not HYP_ALLOWED.match(p):
                bad.append(p)
    return bad

def _build_prompt(log_tail: list, current_fitness: float, baseline_fitness: float) -> str:
    arch = Path("ARCHITECTURE.md").read_text()
    claude_md = Path("CLAUDE.md").read_text() if Path("CLAUDE.md").exists() else ""
    src_files = sorted(Path("rtl").rglob("*.sv"))
    src_dump  = "\n\n".join(
        f"=== {f} ===\n{f.read_text()}" for f in src_files
    )
    log_str = "\n".join(json.dumps(e) for e in log_tail)

    return f"""You are a CPU microarchitecture research agent.

Your job: propose one architectural hypothesis to improve this RV32IM CPU.
Fitness metric: CoreMark iter/sec = CoreMark iterations/cycle × Fmax_Hz on Tang Nano 20K FPGA.
Current best fitness: {current_fitness:.2f}
Baseline fitness: {baseline_fitness:.2f}

## Architecture
{arch}

## Hard invariants (do NOT propose changes that weaken these)
{claude_md}

## Current SystemVerilog Source (rtl/)
{src_dump}

## Recent Experiment Log (last 20 entries)
{log_str if log_str else "(no experiments yet — this is the first iteration)"}

## Instructions
1. Analyze the source and experiment log carefully.
2. Identify the most promising architectural improvement.
3. Write a hypothesis YAML file to: experiments/hypotheses/<id>.yaml

The hypothesis ID must follow the format: hyp-YYYYMMDD-NNN
where NNN is a zero-padded sequence number based on existing files.

The YAML must validate against schemas/hypothesis.schema.json:
  id, title, category, motivation, hypothesis, expected_impact, changes

Each `changes[i].file` must be a path under rtl/ (this is an SV-source-
of-truth project; do NOT propose Chisel/Scala edits).

Write the file now using your Write tool. Do not output anything else."""


def _next_id() -> str:
    HYPOTHESES_DIR.mkdir(parents=True, exist_ok=True)
    today = datetime.date.today().strftime("%Y%m%d")
    existing = list(HYPOTHESES_DIR.glob(f"hyp-{today}-*.yaml"))
    n = len(existing) + 1
    return f"hyp-{today}-{n:03d}"


def run_hypothesis_agent(log_tail: list, current_fitness: float,
                         baseline_fitness: float) -> str:
    """Invokes claude -p and returns path to written hypothesis YAML.

    Sandbox: if the agent touches anything outside experiments/hypotheses/,
    revert those changes and raise. The orchestrator catches this and logs
    a 'broken' iteration without ever running the eval gates.
    """
    hyp_id = _next_id()
    prompt = _build_prompt(log_tail, current_fitness, baseline_fitness)

    # Stream claude output to experiments/hypotheses/.claude.log so Phase 1
    # progress is observable via `tail -f`. Default `claude -p` (text mode)
    # buffers everything until the final response, which makes hypothesis
    # generation look frozen for ~5-10 minutes while the model reads the
    # full rtl/, ARCHITECTURE.md, CLAUDE.md, and the experiment log. The
    # file is gitignored by the global `.claude.log` rule so it does not
    # trip the sandbox check below.
    HYPOTHESES_DIR.mkdir(parents=True, exist_ok=True)
    cmd = [
        "claude", "-p", prompt,
        "--dangerously-skip-permissions",
        "--output-format", "stream-json",
        "--verbose",
    ]
    proc = subprocess.Popen(
        cmd, cwd=".",
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True, bufsize=1,
    )
    with HYPOTHESIS_LOG.open("w") as log:
        for line in proc.stdout:
            log.write(line)
            log.flush()
            try:
                summary = _summarize_event(line)
            except Exception:
                summary = None
            if summary:
                print(f"  [claude] {summary}", flush=True)
    proc.wait()
    if proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, cmd)

    breaches = _git_offlimits_changes()
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

    path = HYPOTHESES_DIR / f"{hyp_id}.yaml"
    if not path.exists():
        # Agent may have chosen a different ID — find the newest file
        files = sorted(HYPOTHESES_DIR.glob("hyp-*.yaml"), key=lambda f: f.stat().st_mtime)
        if files:
            path = files[-1]
        else:
            raise FileNotFoundError("Hypothesis agent did not write a hypothesis file.")
    return str(path)
