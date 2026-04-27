#!/usr/bin/env bash
# Usage: bash fpga/scripts/nextpnr_run.sh <seed> <output_dir>
set -e
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

grep -E "Max frequency" "$OUTDIR/nextpnr.log" | tail -1 || echo "Fmax: N/A"
