#!/usr/bin/env bash
# Usage: bash fpga/scripts/nextpnr_run.sh <seed> <output_dir>
#
# pipefail: without it, `nextpnr-himbaechel … | tee log` masks nextpnr's
# non-zero exit when the pipe (tee) succeeds. fpga.py would then see
# whatever 'Max frequency' line nextpnr printed before the failure and
# score a partial route as a successful seed.
set -eo pipefail

SEED=${1:-1}
OUTDIR=${2:-generated/pnr_seed${SEED}}
mkdir -p "$OUTDIR"

nextpnr-himbaechel \
  --device GW2A-LV18QN88C8/I7 \
  --vopt family=GW2A-18C \
  --json generated/synth.json \
  --write "$OUTDIR/pnr.json" \
  --vopt cst=fpga/constraints/Tang_Nano_20K.cst \
  --seed "$SEED" \
  --timing-allow-fail \
  2>&1 | tee "$OUTDIR/nextpnr.log"

# At this point pipefail has already exit'd if nextpnr crashed. If we
# get here the route ran to completion; surface the final Fmax line.
grep -E "Max frequency" "$OUTDIR/nextpnr.log" | tail -1 || echo "Fmax: N/A"
