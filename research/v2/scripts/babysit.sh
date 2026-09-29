#!/usr/bin/env bash
# One babysitting tick: block until the first of (a) MAX_SEC elapsed (default
# 600), (b) any run completes a round or finishes, (c) a new HIGH/HANG alert,
# (d) the runner log says the campaign/smoke ended, (e) the monitor died;
# then print a status report. Re-armed after every wake.
# Usage: babysit.sh <results.jsonl> <rundir> <runner.log> [MAX_SEC]
# (several results files or runner logs: pass them space-separated in one
# quoted argument)
R=$1; D=$2; L=$3; MAX=${4:-600}
A=~/monitor/alerts.jsonl
cd ~/auto-arch-tournament
sig() {
  for c in /srv/hwebench/clones/*/; do
    # completed rounds: baseline line + 3 slot entries per round (K=3);
    # a log not written yet counts as 0 rounds
    n=$(cat "$c/cores/bench/experiments/log.jsonl" 2>/dev/null | wc -l)
    echo "$c $(( n > 0 ? (n - 1) / 3 : 0 ))"; done
  # a missing file counts as 0 so its creation is not a wake
  cat $R 2>/dev/null | wc -l
  cat "$A" 2>/dev/null | grep -c '"severity": "\(HIGH\|HANG\)"'
}
start=$(sig); t0=$(date +%s); why="10-minute check"
while :; do
  sleep 20
  if grep -q 'matrix done\|SMOKE-EXIT' $L 2>/dev/null; then why="runner finished"; break; fi
  if ! pgrep -f '[m]onitor_run.py.* --loop' >/dev/null; then why="monitor not running"; break; fi
  now=$(sig)
  if [ "$now" != "$start" ]; then why="progress or alert"; break; fi
  [ $(( $(date +%s) - t0 )) -ge "$MAX" ] && break
done
echo "== $(date -u +%H:%M) UTC, woke: $why; $(uptime | sed 's/.*load/load/')"
python3 research/v2/scripts/status_table.py --results $R --rundir "$D"
echo "== broken slots:"
for f in /srv/hwebench/clones/*/cores/bench/experiments/log.jsonl; do
  [ -f "$f" ] || continue   # no clones left (glob unmatched)
  python3 - "$f" <<'PY'
import json, sys
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e.get("outcome") == "broken":
        print("  ", sys.argv[1].split("/")[4], e["id"], str(e.get("error"))[:160].replace("\n", " "))
PY
done
echo "== HIGH/HANG alerts (last 5):"; grep '"severity": "\(HIGH\|HANG\)"' "$A" 2>/dev/null | tail -n 5 | cut -c1-220
echo "== collision mentions to review (MEDIUM, last 3):"; grep 'mentions a collision' "$A" 2>/dev/null | tail -n 3 | cut -c1-260
echo "== eval queue:"; grep -h 'host eval slot' /srv/hwebench/clones/*/.tmp/orchestrator.log 2>/dev/null | tail -n 2
echo "== runner:"; grep -h '===\|matrix\|exception' $L | tail -n 6 | cut -c1-200
