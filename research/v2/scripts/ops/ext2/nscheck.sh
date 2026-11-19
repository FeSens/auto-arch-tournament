#!/usr/bin/env bash
# Agent-account processes by PID namespace: "<count> <user> <host|sandbox> <comm>".
# NSpid with one entry = the host PID namespace; more = inside a sandbox.
for p in /proc/[0-9]*; do
  u=$(stat -c %U "$p" 2>/dev/null) || continue
  case "$u" in hwebench*) ;; *) continue ;; esac
  n=$(awk '/^NSpid:/{print NF-1}' "$p/status" 2>/dev/null) || continue
  [ -n "$n" ] || continue
  c=$(cat "$p/comm" 2>/dev/null) || continue
  [ "$n" -gt 1 ] && ns=sandbox || ns=host
  echo "$u $ns $c"
done | sort | uniq -c
