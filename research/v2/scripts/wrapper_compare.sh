#!/usr/bin/env bash
# Synthesize + place-and-route one design under the V1 or V2 timing harness,
# with the exact relative-path invocation tools/eval/fpga.py uses.
#
# Placement depends on the netlist's names and source attributes, so paths
# must match the harness: the same RTL gave a 127.03 vs 132.43 MHz median
# when only file paths differed (research/v2/NOTES.md, 2026-09-27).
#
# Usage: wrapper_compare.sh <rtl_dir> <v1|v2> <work_dir> [seeds...]
# v1 = fpga/ from branch main; v2 = fpga/ from this working tree.
set -euo pipefail
RTL=$(cd "$1" && pwd); VER=$2; WORK=$3; shift 3
SEEDS=${*:-1 2 3}
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)

rm -rf "$WORK"; mkdir -p "$WORK/cores/bench"
cp -R "$RTL" "$WORK/cores/bench/rtl"
if [ "$VER" = v1 ]; then
  git -C "$REPO" archive main fpga | tar -x -C "$WORK"
else
  cp -R "$REPO/fpga" "$WORK/fpga"
fi
ln -s "$REPO/.toolchain" "$WORK/.toolchain"
# SYNTH_ARGS (flow experiments): extra synth_gowin options, applied to the copy.
if [ -n "${SYNTH_ARGS:-}" ]; then
  sed -i '' "s|synth_gowin -top core_bench|synth_gowin -top core_bench ${SYNTH_ARGS}|" "$WORK/fpga/scripts/synth.tcl"
  grep -q "synth_gowin -top core_bench ${SYNTH_ARGS}" "$WORK/fpga/scripts/synth.tcl"
fi
cd "$WORK"
export PATH="$WORK/.toolchain/oss-cad-suite/bin:$PATH"
mkdir -p cores/bench/generated
RTL_DIR=cores/bench/rtl GEN_DIR=cores/bench/generated BENCH=fpga/core_bench_si.sv \
  yosys -c fpga/scripts/synth.tcl > cores/bench/generated/synth.log 2>&1
for s in $SEEDS; do
  ( bash fpga/scripts/nextpnr_run.sh "$s" "cores/bench/generated/pnr_seed$s" > /dev/null 2>&1 || true
    L="cores/bench/generated/pnr_seed$s/nextpnr.log"
    f=$(grep -E 'Max frequency' "$L" | tail -1 | grep -oE '[0-9.]+ MHz' | head -1 || true)
    a=$(for c in LUT4 DFF RAM16SDP4 BSRAM MULT36X36; do printf '%s=%s ' "$c" "$(grep -oE "\b$c: +[0-9]+" "$L" | tail -1 | grep -oE '[0-9]+$' || echo NA)"; done)
    echo "seed $s: ${f:-FAILED} $a" ) &
done
wait
