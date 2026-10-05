# V2 paper handoff (2026-10-05)

For writing the V2 paper in a fresh session on another machine. Everything
the paper needs is in git on branch `v2` (origin). Nothing below requires
the run host unless a number has to be recomputed.

## Read in this order

1. `research/runs/EXP-2026-09-28-v2-main/README.md`: index of the
   pre-registration, the 16 amendments, every analysis and follow-up study.
2. `research/v2/paper-v2.md`: working notes for the paper. Every finding
   with its status (measured / inferred) and evidence path. Section 7 is the
   results, section 8 the limitations. It is a fact sheet, not paper prose.
3. `research/v2/NOTES.md`: the append-only diary, source of every number.
4. `research/v2/V3.md`: what V2 did not fix.
5. `research/review_log.md` and `research/paper_revision_plan.md`: the V1
   (MLCAD 2026) reviews and the writing items W1 to W9 they produced.

## What is pre-registered and what is not

- Pre-registered (`prereg.yaml` and amendments, committed before the data):
  Opus 5.5 vs GPT-6.1 Sol (primary); both against Luna (amendment 01); the
  12 extension pairs, Holm (amendment 13); the lessons ablation
  (amendment 14); the random-mutation control, textbook-edit baseline and
  Artix-7 study (amendment 15; the Artix-7 tests are reported as
  exploratory in their analysis).
- Exploratory, decided after scoring: the 15 extended kernels, the
  reference cores, placement robustness, deep formal, fetch-bounds formal,
  the agent-class counts.

## Decisions for the author

- V0 provenance. Reviewer R1.c asked where V0 came from, and the July plan
  (W5) says to disclose it plainly (LLM-drafted from a human-written spec,
  gate-validated, frozen). On 2026-09-27 you cut a V0-origin sentence from
  the V1 revision as provenance that bears on no claim. `paper-v2.md` 5a
  currently states it; keep or cut.
- Framing of the random-mutation control. Reviewers wanted a control that
  separates agent reasoning from gates plus blind sampling (R2.b, R3.c).
  Your rule: a control that only sanity-checks the evaluator is framed as
  such. 0 of 135 shows the gates reject blind single-line edits; the
  stronger evidence that agents do more than the gates give away is the
  textbook edit (every scored run beats it, 1.3x to 2.7x) and the reference
  cores.
- V1 erratum. Two V1 results do not hold: the open-source timer missed
  whole path classes (paper-v2.md section 1), and V1's random control was 3
  draws, not 135 (section 4b). Decide whether these go in the V2 paper, a
  separate erratum, or both.
- Scope of the ranking claim. On Gowin there are three tiers, 9 of 12 pairs
  separate. On Artix-7 only the split between the top four and {GPT-5.5,
  Luna} holds. The defensible headline is a ranking on the Gowin contract.

## Writing rules (from the operator sessions)

- No em dashes anywhere (prose, captions, tables, commits). Use commas,
  periods or parentheses; an en dash or an empty cell for missing values.
- Cut sentences that add nothing for the reader: meta-statements the page
  already shows, parenthetical method hedges, diligence boilerplate,
  provenance that bears on no claim.
- Replace quoted jargon with what happened (the sizes tried and why one was
  kept, not "the knee of the sweep"). Define CoreMark, RVFI, Fmax, place and
  route, ALTOPS for an ML reader.
- Lead with the aggregate pattern (pass/fail rates across all runs), not
  the best run.
- Tables: full text width, caption gap, a blank cell (not "unknown") with a
  caption note, the grouping variable in one place.
- Earlier paper drafts (V1 MLCAD/ICLR/FPGA versions) were rated poorly
  written; start fresh rather than revise them.

## Facts that are easy to get wrong

- System names: name the system, not the bare model ("Opus 5.5 (Claude
  Code)", "GPT-6.1 Sol (Codex CLI)"). GPT-6 Sol ran once as an unscored
  pilot before GPT-6.1 Sol replaced it (amendment 11).
- Counts: 36 scored runs (6 systems x 6), plus the pilot, plus 6 no-lessons
  runs, plus 3 random-control runs. N = 15 rounds, K = 3 slots.
- Harness versions: 2.8.2 for every scored run, 2.8.3 for the ablation,
  2.8.4 for the random control (tags hwe-bench-v2.8.x).
- The score's "median of three placements" is effectively one value
  (Gowin place options 1 and 2 build identically).
- The per-round formal gate uses ALTOPS: it does not prove multiplier or
  divider arithmetic. Cosim and the unit tests do. The contract's deep
  formal cannot pass as vendored (DIV/REM spec defect).
- The held-out kernels contain no divide instruction, so the textbook
  edit's gain is all Fmax.
- Monitor alert timestamps are host local time (CEST); everything else is
  UTC.
- Mac-measured numbers are pilots and are never mixed with run-host numbers.
- The held-out ELFs are never published. The kernel sources are public
  benchmarks vendored in `bench/holdout`; the built binaries exist only on
  the run host.

## What stays on the run host, and whether it matters

| Item | Where | Needed for writing |
|---|---|---|
| Run clones, per-run homes | `/srv/hwebench` | No. Every run's git bundle, final RTL, logs and full agent transcript are in `bench/v2/` |
| Held-out ELFs | `bench/holdout/build/` (gitignored) | No. Only to rescore |
| Toolchains (Gowin, oss-cad-suite, Verilator) | `/opt` | Only to rerun anything |
| Formal work trees | `/home/bench/deepformal`, `/home/bench/fetchbounds` | No. Results and counterexamples are committed |
| Vivado projects | operator workstation, `~/hwe-xfpga` | No. Per-design timing summaries are in `research/v2/xfpga/results/*.json` |
| Operator assistant's transcripts and memory | run host, `~/.claude` | No. Decisions and the user's approvals are quoted in the amendments; the writing rules are above |
| Session scratch | `/tmp` on the run host | No. The checks behind cited numbers are scripts in `research/v2/scripts/` |

## Website

hwebench.com is built from `main` (`tools/site/build.py`, GitHub Pages on
push). V2 results are on `v2.html`; the generator is
`tools/site/build_v2.py`, which reads the V2 analysis files on this branch.
