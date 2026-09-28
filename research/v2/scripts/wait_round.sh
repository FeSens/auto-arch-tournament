#!/usr/bin/env bash
# Block until any live or finished run completes a new round (or the campaign
# ends), then print the status table. Usage: wait_round.sh <results.jsonl> <rundir> <runner.log>
R=$1; D=$2; L=$3
rounds() { for f in /srv/hwebench/clones/*/cores/bench/experiments/log.jsonl $D/*/rep*/log.jsonl; do
  [ -f "$f" ] && grep -o '"id": *"hyp-[0-9-]*-r[0-9]*s' "$f" | sed 's/.*-r\([0-9]*\)s/\1/' | sort -un | tail -n 1 | sed "s|^|$f |"; done | sort; }
start=$(rounds)
until [ "$(rounds)" != "$start" ] || grep -q 'matrix done' "$L"; do sleep 60; done
date -u; python3 research/v2/scripts/status_table.py --results "$R" --rundir "$D"
grep -E '"(HIGH|HANG)"' ~/monitor/alerts.jsonl | tail -n 3 | cut -c1-160
