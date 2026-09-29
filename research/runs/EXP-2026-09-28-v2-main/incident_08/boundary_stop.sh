#!/bin/bash
# Stop the 2.8.0 campaign runner the moment rep1's batch is over and rep2's
# batch line appears, before any rep2 agent starts, so reps 2-6 can be
# relaunched with absolute results paths (the relative --results-dir made
# every run's repo.bundle fail, and with it the held-out scoring).
log=/home/bench/auto-arch-tournament/bench/v2/runner.log
pid=437934 pgid=437932
out=/home/bench/rescue-bundles/boundary.log
while kill -0 $pid 2>/dev/null; do
  if grep -q '^\[bench\] batch: .*-rep2' "$log"; then
    kill -KILL -- -$pgid
    echo "$(date -u +%FT%T) rep2 batch line seen; killed runner pgid $pgid" >> "$out"
    ps -eo pid,etime,args | grep -E 'tools\.(bench|orchestrator)|clone_fixture|git clone' | grep -v grep >> "$out"
    exit 0
  fi
  sleep 0.2
done
echo "$(date -u +%FT%T) runner exited on its own" >> "$out"
