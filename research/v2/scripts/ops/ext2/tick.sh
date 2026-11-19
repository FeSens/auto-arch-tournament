#!/usr/bin/env bash
# One amendment-17 babysit tick; shows only alerts newer than the last tick.
O=$HOME/ext2-ops
since=$(cat $O/tick.since 2>/dev/null || echo 2026-11-19T13:00)
TZ=Europe/Berlin date +%Y-%m-%dT%H:%M:%S > $O/tick.since   # the monitor stamps alerts in Berlin time
cd /home/bench/auto-arch-tournament
R=""; L0=""
for f in bench/v2/results-g62*.jsonl bench/v2/results-fable52-*.jsonl; do [ -f "$f" ] && R="$R $f"; done
for f in bench/v2/runner-g62*.log bench/v2/runner-fable52-*.log; do [ -f "$f" ] && L0="$L0 $f"; done
# Smokes (unscored) only while their runner is still going, so they never mask a scored rep.
for t in g62 fable52; do
  sl=bench/v2/smoke-ext2/runner-smoke-$t.log; sr=bench/v2/smoke-ext2/results-smoke-$t.jsonl
  if [ -f "$sl" ] && ! grep -q 'matrix done' "$sl"; then L0="$L0 $sl"; [ -f "$sr" ] && R="$R $sr"; fi
done
R="${R# }"; [ -n "$R" ] || R=/dev/null
# Watch only runners still going: a finished log's "matrix done" would wake every tick.
L=""; for f in $L0; do grep -q 'matrix done' "$f" || L="$L $f"; done; L="${L# }"; [ -n "$L" ] || L=/dev/null
research/v2/scripts/babysit.sh "$R" bench/v2 "$L" "${1:-600}" 2>&1 |
  awk -v s="$since" '/^\{"at": "/ { t=substr($0, 9, 19); if (t < s) next } { print }'
echo "== namespaces now"
sudo -n bash $O/nscheck.sh | awk '$3=="host" && $4!~/^(claude|socat|bwrap|codex|codex-code-mode|codex-linux-san|codex-exec-serv)$/ && !($4~/^(lsb_release|getconf)$/) {print "UNEXPECTED HOST:", $0} $3=="sandbox"{s+=$1} END{print "agent processes in sandboxes:", s+0}'
echo "== shared Codex login (want hwecodex 660):"; sudo -n stat -c '  %n %U:%G %a %y' /srv/hwebench/auth/auth.json /srv/hwebench/auth/auth.json.lock 2>&1
echo "== ext2 launcher:"; tail -n 3 bench/v2/ext2-launcher.log 2>/dev/null | cut -c1-220
echo "== cosim guard kills:"; grep -c KILLED $O/cosim_guard.log 2>/dev/null
echo "== disk:"; df -h / | tail -1
true
