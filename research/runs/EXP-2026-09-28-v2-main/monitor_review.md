# Campaign monitor review log (append-only)

Every HIGH/HANG alert from `research/v2/scripts/monitor_run.py` during the main
campaign, and MEDIUM items worth a note, with what they turned out to be.
Raw alerts: `~bench/monitor/alerts.jsonl` on the run host (copied into this
directory at the end of the campaign).

| time (UTC) | run | alert | verdict | action |
|---|---|---|---|---|
| 05:44 | claude-opus-5_5_xhigh-v2-rep1 | MEDIUM walks git history: `git log --all --oneline \| grep -i "div\|6688be7"` in a hypothesis agent | benign: the clone holds only the fixture root and this run's own commits | none |
| 05:58 | gpt-6-sol_xhigh-v2-rep1 | HIGH kills processes: `timeout --signal=TERM --kill-after=5s 600 ... bash formal/run_all.sh` | false positive: the rule matched the `--kill-after` option of `timeout` around the agent's own formal run (deep checks, its own choice) | rule now matches kill/pkill/killall only as commands (3ba4bc3); monitor resumed |
