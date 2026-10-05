# EXP-2026-09-28-v2-main: the V2 campaign and its follow-ups

Index of what this experiment produced, for the paper. The day-by-day record
is `research/v2/NOTES.md` (append-only); the paper draft is
`research/v2/paper-v2.md`; open problems for V3 are in `research/v2/V3.md`.

## Design and contract

- `prereg.yaml`: the write-once pre-registration (systems, n, primary test,
  incident policy).
- `amendment_01.yaml` to `amendment_16.yaml`: every change after
  pre-registration, each committed before the data it governs.
  - 01: a third system (GPT-6 Luna).
  - 02: leak audit (`research/v2/LEAKS.md`).
  - 03 to 09: incidents 01 to 07, each stopping a campaign before any scored
    data. 10: incident 08 (bundle path).
  - 11: incident 09 (worktree race) and GPT-6.1 Sol replacing GPT-6 Sol.
  - 12: formal could check different RTL than synthesis (sensitivity
    analysis: `amendment_12_step1.md`, `amendment_12_step2.md`).
  - 13: three more systems (Sonnet 5.5, GPT-6 Astra, GPT-5.5).
  - 14: the no-lessons ablation.
  - 15 (plus `amendment_15_models.yaml`): random-mutation control, textbook-edit
    baseline, Artix-7 transfer.
  - 16: harness 2.8.4, fixing the random control's seeding.
- `incident_01` to `incident_09`: aborted-run data, runner logs and monitor
  alerts for each incident; the account of each is in NOTES and in the
  paper draft (section 5c).

## Results

| Question | Analysis | Data |
|---|---|---|
| Main ranking, six systems x 6 runs (primary and amendment 01/13 tests) | `analysis_final.md` | `bench/v2/<system>/rep<N>/`, `bench/v2/results-*.jsonl` |
| Per-system finals at the time each finished | `analysis_main_campaign_end.md`, `analysis_astra_final.md`, `analysis_sonnet55_final.md` | as above |
| Lessons ablation (amendment 14) | `analysis_ablation.md` | `bench/v2/gpt-6_1-sol_xhigh-v2-nolessons/`, `bench/v2/results-sol61nl-*.jsonl` |
| Random-mutation control (amendment 15 A, 16) | `research/v2/random_control/analysis.md` | `bench/v2/random-mutation-v2/`, `bench/v2/results-rand-*.jsonl`; smoke20 in `bench/v2/smoke-rand/` |
| Textbook-edit baseline (amendment 15 B) | `research/v2/textbook_baseline/README.md` | `research/v2/textbook_baseline/results/` |
| Artix-7 transfer (amendment 15 C) | `research/v2/xfpga/results/analysis.md` | `research/v2/xfpga/results/*.json` |
| 15 unseen Embench-IoT kernels (exploratory) | `research/v2/extended_bench/` | same |
| Human reference cores on the same flow | `research/v2/reference_cores/` | same |
| Placement robustness (6 Gowin settings) | `research/v2/placement/results/analysis.md` | `research/v2/placement/results/builds.jsonl` |
| Deep formal, real M-extension arithmetic (pilot) | `research/v2/deep_formal/README.md` | `research/v2/deep_formal/results/` |
| Fetch-address bounds formal | `research/v2/fetch_bounds/README.md` | `research/v2/fetch_bounds/results/` |

## Operations

- `monitor/alerts.jsonl`, `monitor/counts.json`, `monitor/monitor-*.log.gz`:
  the campaign monitor's output (timestamps in host local time, CEST).
  `monitor_review.md` reviews every alert class that needed a decision.
- `ops/`: the operator's memory watch and cosim guard logs. Scripts in
  `research/v2/scripts/ops/`.
