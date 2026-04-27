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

    subprocess.run(
        ["claude", "-p", prompt, "--dangerously-skip-permissions"],
        cwd=".",
        check=True,
    )

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
