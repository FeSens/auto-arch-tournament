"""Scribe agent: distills one-line lessons from each tournament iteration's
outcome + RTL diff, appending to cores/<target>/LESSONS.md.

Triggered after every slot's append_log under the orchestrator's _LOG_LOCK
(see tools.orchestrator.append_log). The scribe's only permitted side-effect
is one append to LESSONS.md; any other file modification is reverted via
`git checkout HEAD --` and the call is reported as off-limits.
"""
import re
import subprocess
from pathlib import Path

from tools.agents._runtime import build_agent_cmd, run_agent_streaming


# Tight cap. The scribe writes one bullet from a small prompt; if it has not
# returned in two minutes something is wrong and we'd rather skip the lesson
# than block the loop.
SCRIBE_TIMEOUT_SEC = 120

# Bound the diff embedded in the scribe prompt. A 30 KB rewrite-everything
# diff has the same lesson-content as an 8 KB excerpt; the trimming is for
# token budget, not signal.
DIFF_MAX_CHARS = 8000


def lessons_path(target: str) -> Path:
    return Path("cores") / target / "LESSONS.md"


def scribe_log_path(target: str) -> Path:
    return Path("cores") / target / "experiments" / ".scribe.log"


def _allowed_re(target: str) -> 're.Pattern':
    """Sandbox: scribe may only touch cores/<target>/LESSONS.md."""
    return re.compile(rf"^cores/{re.escape(target)}/LESSONS\.md$")


def _git_offlimits(allow_re: 're.Pattern') -> list:
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


def _truncate_diff(diff: str, max_chars: int = DIFF_MAX_CHARS) -> str:
    if len(diff) <= max_chars:
        return diff
    return diff[:max_chars] + "\n[... diff truncated ...]\n"


def _build_prompt(entry: dict, diff: str, target: str) -> str:
    hyp = entry.get("hypothesis") or {}
    notes = entry.get("implementation_notes") or "(no notes)"
    delta = entry.get("delta_pct")
    delta_str = f"{delta:+.2f}%" if isinstance(delta, (int, float)) else "n/a"
    fitness = entry.get("fitness")
    fitness_str = f"{fitness:.2f}" if isinstance(fitness, (int, float)) else "n/a"
    diff_block = _truncate_diff(diff) if diff else "(no diff captured)"

    return f"""You are a scribe distilling one-line research lessons.

A CPU microarchitecture experiment just finished on cores/{target}/. Your job
is to append AT MOST ONE bullet to cores/{target}/LESSONS.md summarizing what
was learned, OR write nothing at all if no useful lesson can be distilled.

## This iteration

- id:        {entry.get('id', 'unknown')}
- title:     {entry.get('title', 'unknown')}
- category:  {entry.get('category', 'unknown')}
- outcome:   {entry.get('outcome', 'unknown')}
- fitness:   {fitness_str}
- delta_pct: {delta_str}
- error:     {entry.get('error') or 'none'}

Motivation:
{hyp.get('motivation', '(none)')}

Hypothesis:
{hyp.get('hypothesis', '(none)')}

Expected impact:
{hyp.get('expected_impact', '(none)')}

Implementation notes (the implementing agent's self-report):
{notes}

RTL diff (cores/{target}/rtl/) — what was actually changed:
```
{diff_block}
```

## Your job

Append at most ONE bullet to cores/{target}/LESSONS.md, in this format:

  - YYYY-MM-DD <id> (<outcome>, <delta_pct>): <one-sentence lesson>

A useful lesson:
  - Captures *why* the outcome happened, not just *what* happened.
  - Generalizes to future iterations (a pattern, gotcha, or design constraint),
    not a one-off bug.
  - Names specific RTL constructs / hazards / CoreMark behaviors when relevant.

Examples of GOOD lessons (do not copy verbatim — write your own):
  - "Dual-issue without a 2W register file creates WAW hazards riscv-formal's
    'reg' check catches; reg file must expose two write ports."
  - "64-entry BHT regressed CoreMark; the always-not-taken default was already
    well-tuned to this benchmark's branch profile."
  - "Adding a fetch buffer gained Fmax (+12 MHz) but blew the LUT budget by
    30% on Tang Nano 20K — fetch-side area is the binding constraint."

SKIP (write nothing — do not modify any file) if:
  - The cause of the outcome is unclear from the available info.
  - The bug was a trivial typo / missing default arm with no general lesson.
  - This iteration plainly duplicates an already-recorded lesson.

If cores/{target}/LESSONS.md does not exist, create it with the single bullet.
If it exists, APPEND to its end (preserve all prior content).

Do NOT modify ANY other file. Do NOT print the bullet — write it to the file.
Do NOT add headers, sections, prose, or anything other than the bullet line.
"""


def run_scribe_agent(entry: dict, diff: str, target: str) -> str | None:
    """Invoke the scribe agent. Returns the appended line, or None if nothing was added.

    Sandbox: only cores/<target>/LESSONS.md is writable; any other touched
    path is reverted and the function raises PermissionError. A scribe that
    rewrites LESSONS.md instead of appending is also reverted (we want the
    file to be append-only — that's the contract the hypothesis prompt and
    git history both depend on).

    Args:
      entry  — the log entry just produced for this slot. The scribe
               consumes id/title/category/outcome/delta_pct/error plus
               the embedded `hypothesis` sub-object and `implementation_notes`.
      diff   — RTL diff as captured by tournament._capture_slot_diff. May be
               "" when no worktree existed (e.g. hypothesis-gen failed).
      target — core name under cores/.
    """
    path = lessons_path(target)
    before_text = path.read_text() if path.exists() else ""

    prompt = _build_prompt(entry, diff, target)
    log_path = scribe_log_path(target)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    last_msg = log_path.parent / f".scribe.{entry.get('id', 'unknown')}.last"
    cmd = build_agent_cmd(
        prompt, cwd=".",
        output_last_message=last_msg,
        enable_search=False,
    )
    rc, timed_out = run_agent_streaming(
        cmd, cwd=".", log_path=log_path, timeout_sec=SCRIBE_TIMEOUT_SEC,
        mode="a",
    )
    if timed_out:
        raise TimeoutError(f"scribe timed out after {SCRIBE_TIMEOUT_SEC}s")
    if rc != 0:
        raise subprocess.CalledProcessError(rc, cmd)

    # Sandbox: revert any path the scribe touched outside its allow-list.
    allow_re = _allowed_re(target)
    breaches = _git_offlimits(allow_re)
    if breaches:
        for p in breaches:
            subprocess.run(["git", "checkout", "HEAD", "--", p],
                           capture_output=True)
            pp = Path(p)
            if pp.exists():
                tracked = subprocess.run(
                    ["git", "ls-files", p], capture_output=True, text=True,
                ).stdout.strip()
                if not tracked:
                    pp.unlink(missing_ok=True)
        raise PermissionError(
            f"scribe touched off-limits paths and was rolled back: {breaches}"
        )

    # Append-only contract: the new file content must START WITH the old
    # content. A scribe that rewrote the file gets reverted to the prior
    # state — we'd rather lose the lesson than silently lose history.
    if not path.exists():
        return None
    after_text = path.read_text()
    if after_text == before_text:
        return None
    if not after_text.startswith(before_text):
        if before_text:
            path.write_text(before_text)
        else:
            path.unlink(missing_ok=True)
        raise PermissionError(
            f"scribe rewrote {path} instead of appending; reverted to prior content"
        )
    new_part = after_text[len(before_text):].strip()
    return new_part or None
