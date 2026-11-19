#!/usr/bin/env bash
# Sample agent namespaces every 15 s while a smoke runs (amendments 08/09 practice).
# Usage: nssample.sh <out.log> <seconds>
out=$1; end=$(( $(date +%s) + ${2:-7200} ))
while [ "$(date +%s)" -lt "$end" ]; do
  echo "== $(date -u +%FT%TZ)" >> "$out"; sudo -n /bin/true 2>/dev/null
  sudo -n bash "$HOME/ext2-ops/nscheck.sh" >> "$out" 2>/dev/null
  sleep 15
done
