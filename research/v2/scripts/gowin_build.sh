#!/usr/bin/env bash
# Pilot: synthesize + place-and-route one design with the vendor's Gowin EDA
# (Education edition) instead of Yosys + nextpnr, on the same wrapper, stall
# generator, pinout and part. Prints "fmax <MHz> lut4 <n> ..." on success.
# Usage: gowin_build.sh <rtl_dir> <work_dir> [place_option]
set -euo pipefail
RTL=$(cd "$1" && pwd); WORK=$2; POPT=${3:-0}
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
GW=${GOWIN_HOME:-$HOME/gowin}
export LD_LIBRARY_PATH=$GW/deps/root/usr/lib/x86_64-linux-gnu:$GW/IDE/lib
export QT_QPA_PLATFORM=offscreen XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/gw-$(id -u)}
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
rm -rf "$WORK"; mkdir -p "$WORK/src"
cp "$RTL"/*.sv "$WORK/src/"
cp "$REPO/fpga/core_bench_si.sv" "$REPO/fpga/bench_stall_gen.sv" "$REPO/fpga/constraints/Tang_Nano_20K.cst" "$WORK/src/"
# Gowin P&R needs an I/O standard per port (the board's banks are 3.3 V);
# nextpnr ignores these, so they go in the pilot's copy only.
printf 'IO_PORT "clock" IO_TYPE=LVCMOS33;\nIO_PORT "reset" IO_TYPE=LVCMOS33;\nIO_PORT "led" IO_TYPE=LVCMOS33;\n' >> "$WORK/src/Tang_Nano_20K.cst"
# The clock target only steers optimization; Fmax is read from the report.
echo 'create_clock -name clock -period 5 [get_ports {clock}]' > "$WORK/src/timing.sdc"
{
  echo "set_device GW2AR-LV18QN88C8/I7 -device_version C"
  echo "add_file src/core_pkg.sv"
  for f in "$WORK"/src/*.sv; do b=$(basename "$f"); [ "$b" = core_pkg.sv ] || echo "add_file src/$b"; done
  echo "add_file src/Tang_Nano_20K.cst"
  echo "add_file src/timing.sdc"
  echo "set_option -top_module core_bench"
  echo "set_option -verilog_std sysv2017"
  echo "set_option -output_base_name core_bench"
  echo "set_option -place_option $POPT"
  echo "set_option -gen_text_timing_rpt 1"
  echo "run all"
} > "$WORK/build.tcl"
cd "$WORK" && "$GW/IDE/bin/gw_sh" build.tcl > gw.log 2>&1 || { tail -n 30 gw.log; exit 1; }
TR=$(ls impl/pnr/*.tr 2>/dev/null | head -n 1)
fmax=$(grep -A6 -i "Max Frequency Summary" "$TR" | grep -E "clock" | grep -oE "[0-9]+\.[0-9]+\(MHz\)" | head -n 1 | tr -d '(MHz)')
lut=$(grep -E "^\s*(Logic|LUT)" impl/pnr/core_bench.rpt.txt | head -n 3 | tr -s ' ' | tr '\n' ';')
echo "fmax ${fmax:-NA} | $lut"
