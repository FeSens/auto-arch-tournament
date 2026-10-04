#!/usr/bin/env bash
# One campaign babysit tick; shows only alerts newer than the last tick.
S=/tmp/claude-1000/-home-bench-auto-arch-tournament/c4aa8f8e-836f-4266-9ad0-a31f867c07f9/scratchpad
since=$(cat $S/tick.since 2>/dev/null || echo 2026-09-29T22:19)
TZ=Europe/Berlin date +%Y-%m-%dT%H:%M:%S > $S/tick.since
cd /home/bench/auto-arch-tournament
# Amendment 13: the extension runners' files join once they exist.
R="bench/v2/results.jsonl bench/v2/results-opus-luna.jsonl bench/v2/results-sol61.jsonl"
L0="bench/v2/runner-opus-luna.log bench/v2/runner-sol61.log"
for t in astra sonnet55 gpt55; do
  [ -f bench/v2/results-$t.jsonl ] && R="$R bench/v2/results-$t.jsonl"
  [ -f bench/v2/runner-$t.log ] && L0="$L0 bench/v2/runner-$t.log"
done
# Watch only runners still going: a finished log's "matrix done" would wake every tick.
L=""; for f in $L0; do grep -q 'matrix done' "$f" || L="$L $f"; done; L="${L# }"
research/v2/scripts/babysit.sh "$R" bench/v2 "$L" "${1:-600}" 2>&1 |
  awk -v s="$since" '/^\{"at": "/ { t=substr($0, 9, 19); if (t < s) next } { print }'
echo "== namespaces now"
/tmp/claude-1000/nscheck.sh | awk '$3=="host" && $4!~/^(claude|socat|bwrap|codex|codex-code-mode|codex-linux-san)$/ && !($4~/^(lsb_release|getconf)$/ && $2~/^hwebench3?$/) {print "UNEXPECTED HOST:", $0} $3=="sandbox"{s+=$1} END{print "agent processes in sandboxes:", s+0}'
echo "== champion RTL that differs by tool (new since last tick):"
python3 - "$since" <<'PY'
import json, sys
for l in open("/home/bench/monitor/alerts.jsonl"):
    a = json.loads(l)
    if a["at"] >= sys.argv[1] and a["what"].startswith("RTL behaves differently") and " champion " in " " + a["detail"]:
        print("  ", a["at"], a["run"], a["detail"][:120])
PY
echo "== extension launcher:"; tail -n 3 bench/v2/ext-launcher.log 2>/dev/null; tail -n 2 bench/v2/smoke-ext/runner-smoke-sonnet55.log 2>/dev/null
echo "== worktree retries:"; grep -h "worktree\] git" /srv/hwebench/clones/*/.tmp/orchestrator.log 2>/dev/null | tail -3
true
