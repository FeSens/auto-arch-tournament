#!/bin/bash
# Keep an up-to-date `git bundle --all` of each live rep1 clone until the
# runner deletes it (the 2.8.0 runner's own bundle fails on a relative
# results dir; V2 2.8.0 campaign, Opus rep1 lost its bundle at 16:52Z).
# Read-only on the clone. Re-bundles whenever any ref moves.
out=/home/bench/rescue-bundles
declare -A last
while :; do
  alive=0
  for run in "$@"; do
    c=/srv/hwebench/clones/$run
    [ -d "$c/.git" ] || continue
    alive=1
    refs=$(git -C "$c" for-each-ref --format='%(objectname) %(refname)' 2>/dev/null; git -C "$c" rev-parse HEAD 2>/dev/null)
    [ -n "$refs" ] || continue
    h=$(printf '%s' "$refs" | sha1sum | cut -c1-40)
    if [ "${last[$run]}" != "$h" ]; then
      if git -C "$c" bundle create "$out/$run.bundle.tmp" --all >/dev/null 2>&1; then
        mv -f "$out/$run.bundle.tmp" "$out/$run.bundle"
        last[$run]=$h
        echo "$(date -u +%H:%M:%S) $run bundled $(git -C "$c" rev-parse --short HEAD 2>/dev/null) $(git -C "$c" log -1 --format=%s 2>/dev/null)" >> "$out/watch.log"
      fi
    fi
  done
  [ $alive = 1 ] || { echo "$(date -u +%H:%M:%S) all clones gone" >> "$out/watch.log"; exit 0; }
  sleep 2
done
