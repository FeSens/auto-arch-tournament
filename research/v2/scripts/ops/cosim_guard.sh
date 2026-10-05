#!/bin/bash
# Operator guard for the harness-cosim runaway class (NOTES 2026-09-30, 2026-10-04):
# when MemAvailable < 4 GB, SIGKILL any test/cosim/run_cosim.py process holding
# > 20 GB RSS (the process the kernel OOM killer would take, without the swap
# storm first). Owner bench (harness evals) or, since 2026-10-05 01:4xZ, an
# agent account hwebench* (agent-side probes; Sep 29 OOM kill, Oct 2 near miss,
# Oct 5 01:36Z operator kill). The slot fails cosim either way. Every kill is
# logged; nothing else is ever touched.
LOG=/tmp/claude-1000/-home-bench-auto-arch-tournament/c4aa8f8e-836f-4266-9ad0-a31f867c07f9/scratchpad/cosim_guard.log
echo "$(date -u +%FT%TZ) guard started" >> $LOG
while true; do
  avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  if [ "$avail" -lt 4000 ]; then
    ps -eo pid=,user:16=,rss=,args= | awk '($2=="bench" || $2 ~ /^hwebench[0-9]*$/) && $3>20971520 && /test\/cosim\/run_cosim\.py/ {print $1, $3, $2}' |
    while read -r pid rss owner; do
      args=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | cut -c1-240)
      { kill -9 "$pid" 2>/dev/null || sudo -n kill -9 "$pid" 2>/dev/null; } && echo "$(date -u +%FT%TZ) KILLED pid=$pid owner=$owner rss=$((rss/1024))MB avail=${avail}MB $args" >> $LOG
    done
  fi
  sleep 1
done
