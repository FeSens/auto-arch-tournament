#!/usr/bin/env bash
# Repeats tick.sh until 10 minutes pass, a runner finishes, the monitor dies,
# or a tick shows a HIGH/HANG alert or a collision mention; prints every
# tick's alert sections and the last full tick.
S=/tmp/claude-1000/-home-bench-auto-arch-tournament/c4aa8f8e-836f-4266-9ad0-a31f867c07f9/scratchpad
t0=$(date +%s); alerts=""
while :; do
  out=$(bash $S/tick.sh 600)
  # The operator's own research formal jobs (no run) trip "running long"
  # every minute; those are known (monitor_review 11:50Z) and skipped here.
  a=$(printf '%s\n' "$out" | sed -n '/== HIGH/,/== eval queue/p' | grep -v '^==' |
      grep -v '"run": "?", "what": "[a-z]* running long"')
  [ -n "$a" ] && alerts="$alerts
$a"
  why=$(printf '%s\n' "$out" | head -1)
  case "$why" in *"progress or alert"*) ;; *) break ;; esac
  [ -n "$a" ] && break
  [ $(( $(date +%s) - t0 )) -ge 600 ] && break
done
printf '%s\n' "$out"
[ -n "$alerts" ] && printf '== alerts seen during this window:%s\n' "$alerts"
true
