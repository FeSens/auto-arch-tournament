# Post-run checklist: claude-opus-5_5_xhigh rep1 (launch 2)

Run from the repo root, `/Users/bonetto/bonetto/auto-arch-tournament`. Nothing here pushes or deploys. The operator pushes at the end, and GitHub Pages rebuilds the site from the pushed commit (`.github/workflows/pages.yml`).

## 0. Wait for the runner to finish

The runner (`python3 -m tools.bench.runner --models tools/bench/models-opus55-xhigh.yaml ...`) does the copying itself. At the end it:
- writes `bench/claude-opus-5_5_xhigh/rep1/`: `log.jsonl` (rebuilt from git if that recovers more entries), `run_summary.json`, `agent.log` (compacted), `agent.full.log.gz`, `orchestrator.log`, `env.json`, `summary.json` and `repo.bundle`;
- then appends one row to `bench/results.jsonl`.

Done means the row is present:

```sh
grep '"model":"claude-opus-5_5_xhigh"' bench/results.jsonl
tail -5 bench/logs/opus55-xhigh-run.log
pgrep -f "tools.bench.runner.*opus55" || echo "runner exited"
```

Then run the SBY sweep. Stopping or finishing a bench run can leave formal jobs alive:

```sh
pgrep -fl 'sby|bitwuzla|smtbmc' || echo "no formal jobs left"
```

The clone `../aat-bench-runs/claude-opus-5_5_xhigh-rep1` is kept (`--keep-clones`). Do not delete it until publication is done.

## 1. Check the rep folder

```sh
ls -la bench/claude-opus-5_5_xhigh/rep1
python3 -c "import json;d=json.load(open('bench/claude-opus-5_5_xhigh/rep1/summary.json'));print({k:d.get(k) for k in ['status','final_fitness','best_fitness','iterations','accepted','rejected','broken','broken_by_class','fixture_commit','runner_commit','runner_dirty','api_equivalent_cost_usd','total_cost_usd','total_tokens_in','total_tokens_out']})"
wc -l bench/claude-opus-5_5_xhigh/rep1/log.jsonl      # expect 46 (baseline + 45)
du -h bench/claude-opus-5_5_xhigh/rep1/agent.log      # GitHub warns above 50 MB, rejects above 100 MB
git check-ignore bench/claude-opus-5_5_xhigh/rep1/repo.bundle bench/claude-opus-5_5_xhigh/rep1/agent.full.log.gz   # both must print
```

- `status` must be `done`. If it is not, stop and write up the failure instead.
- `total_cost_usd` should be `0.0` and `api_equivalent_cost_usd` should be set (OAuth Claude rows).
- `runner_dirty` may be `true`: provenance is taken at launch from `git status -- tools`, and `tools/` may already have had the uncommitted site and report edits then. If so, fill `{{RUNNER_DIRTY_NOTE}}` with a sentence saying that the uncommitted paths were site and report code (`tools/site/`, `tools/bench/report.py`) that does not score candidates. Candidates are scored by the clone's own orchestrator and eval code (the fixture, `132c378`), so a dirty runner checkout can affect only the runner's summaries. Confirm that the runner code itself was clean: `git diff <runner_commit> -- tools/bench/runner.py tools/bench/telemetry.py tools/bench/transcript.py; git log --oneline <runner_commit>..HEAD -- tools/bench` (expect no runner or summary changes). If `runner_dirty` is `false`, delete the placeholder.

## 2. Fill the README placeholders

Print every placeholder value and the regenerated accepted-designs table from the final journal:

```sh
python3 - bench/claude-opus-5_5_xhigh/rep1 <<'EOF'
import collections, json, sys
from pathlib import Path
rep = Path(sys.argv[1])
log = [json.loads(l) for l in (rep / "log.jsonl").read_text().splitlines() if l.strip()]
row = json.loads((rep / "summary.json").read_text())
cands = [e for e in log if e.get("round_id", 0) != 0]
wins = [e for e in cands if e.get("outcome") in ("improvement", "accepted")]
cls = collections.Counter((e.get("error") or "").split(":")[0] for e in cands if e.get("outcome") == "broken")
print("candidates", len(cands), "outcomes", dict(collections.Counter(e.get("outcome") for e in cands)))
print("broken classes", dict(cls))
best = max(wins, key=lambda e: e["fitness"])
vals = {
    "FINAL_FITNESS": row.get("final_fitness"), "DELTA_PCT": round(row.get("delta_pct") or 0, 2),
    "LAST_IMPROVING_ROUND": wins[-1]["round_id"],
    "WALL_TIME_SEC": f"{row.get('wall_clock_sec', 0):,}",
    "N_IMPROVEMENTS": len(wins),
    "N_REGRESSIONS": sum(e.get("outcome") == "regression" for e in cands),
    "N_BROKEN": sum(e.get("outcome") == "broken" for e in cands),
    "N_HYPGEN_FAILED": cls.get("hypothesis_gen_failed", 0),
    "N_FORMAL_FAILED": cls.get("formal_failed", 0),
    "N_OTHER_BROKEN": sum(v for k, v in cls.items() if k not in ("hypothesis_gen_failed", "formal_failed")),
    "SANDBOX_VIOLATIONS": cls.get("sandbox_violation", 0),
    "FIXTURE_COMMIT": row.get("fixture_commit"), "RUNNER_COMMIT": row.get("runner_commit"),
    "RUNNER_DIRTY": str(row.get("runner_dirty")).lower(),
    "API_EQUIV_COST_USD": row.get("api_equivalent_cost_usd"),
    "TOKENS_IN": f"{row.get('total_tokens_in', 0):,}", "TOKENS_OUT": f"{row.get('total_tokens_out', 0):,}",
    "ACCEPTED_LEGACY": row.get("accepted"), "BEST_ROUND_INDEX": row.get("best_round"),
    "FINAL_LUT4": best.get("lut4"), "FINAL_FF": best.get("ff"), "FINAL_FMAX": best.get("fmax_mhz"),
    "FMAX_SEEDS": " / ".join(f"{s:.2f}" for s in best.get("seeds", [])),
    "FINAL_CYCLES": f"{best.get('cycles', 0):,}",
}
for k, v in vals.items():
    print(f"{{{{{k}}}}} = {v}")
print("\n| Round, slot | Change (journal title, verbatim) | Fitness | LUT4 | Fmax median MHz |")
print("|---|---|---:|---:|---:|")
for e in wins:
    print(f"| r{e['round_id']}s{e['slot']} | {e['title']} | {e['fitness']:.2f} | {e['lut4']} | {e['fmax_mhz']:.2f} |")
for e in cands:
    if (e.get("error") or "").startswith("formal_failed"):
        print("formal_failed:", f"r{e['round_id']}s{e['slot']}", e["title"], "|",
              [l for l in e["error"].splitlines() if l.startswith(("Formal:", "Failed:"))])
EOF
```

Then edit `bench/claude-opus-5_5_xhigh/README.md`:
- Replace every `{{...}}` with the printed values. `final_fitness` must equal the best accepted fitness in the table. If it does not, investigate before publishing.
- Replace the whole accepted-designs table with the printed one, and delete `{{ACCEPTED_ROWS_AFTER_R13}}`.
- `{{FORMAL_FAILED_NOTE_AFTER_R13}}`: describe any formal failure after r13s2 the same way (failing checks from the printed lines), or delete it.
- `{{AUDIT_SCOPE_AFTER_R13}}`: if round 14 or 15 accepted a design, audit it the same way (changed paths confined to `cores/bench/rtl/` and cocotb tests, no CoreMark constants) and write ", and the rNsM design" here. Until that is done, say in the text that it is not audited. Otherwise delete the placeholder. Also check any new winner for the stall-only, divider and RVFI patterns and add a caveat bullet if one applies.
- `{{FINAL_RAM_CELLS_NOTE}}`: the final design's LUT-RAM and BSRAM cell counts from the orchestrator or FPGA report of the winning slot (launch 1's r6 design used 32 RAM16SDP4 and 4 BSRAM), or delete it.
- Check that "highest fitness recorded on this benchmark so far" is still true against `bench/results.jsonl`. It must keep the n=1 qualifier.
- Delete the DRAFT comment at the top.
- Confirm there are no placeholders or em-dashes left:
  `grep -n -e '{{' -e "$(printf '\342\200\224')" bench/claude-opus-5_5_xhigh/README.md` (the second pattern is an em-dash; expect no output).

## 3. Site: release-chart entry (needs the Opus 5.5 release date)

`tools/site/test_build.py::test_release_chart_covers_every_scored_model_and_renders_labels` fails as soon as the row is in `bench/results.jsonl` without a `MODEL_RELEASES` entry. Add to `MODEL_RELEASES` in `tools/site/build.py`, using the confirmed public release date:

```python
    # First documented Claude Code support: Claude Code 2.1.280 changelog
    # ("Added Claude Opus 5.5 (`claude-opus-5-5`)"), released <DATE>.
    "claude-opus-5_5_xhigh":{"date": "<YYYY-MM-DD>", "label": "Claude Opus 5.5 xhigh", "provider": "anthropic"},
```

Add the source to the release-chart caption in `render_index`, next to the OpenAI, Gemini and Kimi links:

```html
      <a href="https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md" class="ext">Claude Code changelog</a>,
```

The `anthropic` provider color (`var(--c4)`) and the rest of the wiring are already in place (step 5 lists them).

## 4. Build and test locally

```sh
python3 -m pytest -q tools/site                 # all must pass, including the release-chart coverage test
python3 -m tools.bench.report                   # rewrites bench/LEADERBOARD.md and bench/leaderboard.csv
python3 -m tools.site.build                     # rewrites site/{index,models,methodology,data}.html
```

Check the output by eye (for example `open site/models.html#claude-opus-5_5_xhigh`):
- Models page: the Opus section shows the run note (runtime, n=1, isolation, launch history, timeouts, caveats, cost, tokens) and a link to `bench/claude-opus-5_5_xhigh/README.md`.
- Index: the n=1 footnote under the leaderboard lists `claude-opus-5_5_xhigh`. If Opus leads, the "current best" sentence carries "(one repetition, n=1; untested)".
- Data page: rep1 links to `log.jsonl`, `agent.log` and `summary.json`.

`tools/site/watch_publish.py` does **not** publish this row. It only tracks `SCHEDULED_MODELS`, and it refuses to run while `tools/site` or `tools/bench/report.py` has uncommitted changes. Publish by hand (step 6).

## 5. Site code that must be in the publishing commit

CI builds the site from the committed `tools/site/build.py`, so the notes appear only if these are committed:
- `tools/site/run_notes.py` and `tools/site/test_run_notes.py`: already committed.
- Hunks in `tools/site/build.py` (not committed, because the file also holds uncommitted GPT-6 Astra work): the `run_notes` import, `"anthropic": "var(--c4)"` in `PROVIDER_COLORS`, `{render_single_rep_caveat(aggs)}` under the leaderboard, `{leader_sample_caveat(leader)}` in the "current best" sentence, and `configuration_note += render_run_note(a)` in `render_models`. Plus the step 3 hunks.
- Hunk in `tools/site/test_build.py` (not committed, same reason): `test_site_renders_opus_row_with_note_and_caveats`, which renders a stand-in Opus row through the index, models and data pages.

The Pages workflow triggers on `tools/site/build.py`, not on `run_notes.py`. A change to `run_notes.py` alone does not redeploy. Use `workflow_dispatch` or bundle it with a data change.

## 6. Commit (operator), then push

Decide first how the uncommitted Astra hunks in `tools/site/build.py`, `tools/site/test_build.py`, `tools/site/test_watch_publish.py`, `tools/bench/report.py` and `bench/results.jsonl` (three Astra rows) ship. They must go in the same or an earlier commit, because the Opus row sits below them in `bench/results.jsonl` and the build hunks are interleaved with them.

```sh
git add bench/results.jsonl bench/claude-opus-5_5_xhigh/README.md \
        bench/claude-opus-5_5_xhigh/rep1 \
        bench/LEADERBOARD.md bench/leaderboard.csv \
        site/index.html site/models.html site/methodology.html site/data.html \
        tools/site/build.py tools/site/test_build.py
git status --short     # rep1/repo.bundle and rep1/agent.full.log.gz must NOT be staged
git commit -m "bench: publish claude-opus-5_5_xhigh rep1 (N=1, <fitness>, +<delta>%, <k> improvements, <b> broken)"
```

Optionally also delete this checklist in that commit, or keep it as a record. Add a diary entry (`research/diary/<date>.md`) with the final outcome counts, and the research notes in the same form as the Sol publish (`research/lessons.md`, `research/experiments/EXP-...`).

## 7. Top-level README

No edit needed. `README.md` has no per-model results table (the "What came out of it" section describes the original `cores/v1` run), and the GPT-6 Sol publish did not touch it. Per-model results live in `bench/LEADERBOARD.md`, the site and `bench/<config>/README.md`. If a pointer is wanted, add one line after the "Full writeup" link:

```markdown
Benchmark results for each model configuration: <https://hwebench.com>, [`bench/LEADERBOARD.md`](bench/LEADERBOARD.md), and per-configuration notes in `bench/<config>/README.md`.
```
