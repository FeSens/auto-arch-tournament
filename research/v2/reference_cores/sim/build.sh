#!/bin/bash
# Build the stage 2 simulator for one reference core:
#   build.sh <core>   ->  ~/refcores/sim/<core>/Vref_top
set -euo pipefail
core=$1
HERE=$(cd "$(dirname "$0")" && pwd)
RC=$HOME/refcores
OUT=$RC/sim/$core
export PATH=/opt/hwe-toolchain/oss-cad-suite/bin:$PATH
srcs=(); incs=(); flags=()
case $core in
  picorv32) srcs=($RC/picorv32/picorv32.v) ;;
  ueriscv) srcs=($(ls $RC/riscv/core/riscv/*.v | grep -v -E 'riscv_defs.v|riscv_trace_sim.v|riscv_xilinx_2r1w.v'))
           incs=(-I$RC/riscv/core/riscv) ;;
  biriscv) srcs=($(ls $RC/biriscv/src/core/*.v | grep -v -E 'biriscv_defs.v|biriscv_trace_sim.v|biriscv_xilinx_2r1w.v'))
           incs=(-I$RC/biriscv/src/core) ;;
  hazard3) srcs=($(sed -n 's#^file #'$RC'/Hazard3/hdl/#p' $RC/Hazard3/hdl/hazard3.f))
           incs=(-I$RC/Hazard3/hdl) ;;
  neorv32) srcs=($RC/sim/neorv32_ghdl/neorv32_cpu_flat.v) ;;   # sim/ghdl_neorv32.sh
  ibex_small|ibex_maxperf) srcs=($RC/sim/${core}_gen/ref_top.v) ;;   # sim/ibex_sim_sv2v.sh
  vexriscv_nocache) srcs=($RC/vexriscv_nocache/VexRiscv.v) ;;
  vexriscv_maxperf) srcs=($HOME/vexref/VexRiscv/VexRiscv_GenFullNoMmuMaxPerf.v) ;;
  vexiiriscv) srcs=($RC/vexiiriscv_benchmap/VexiiRiscv.v) ;;
  *) echo "unknown core $core"; exit 1 ;;
esac
rm -rf $OUT; mkdir -p $OUT
verilator --cc --exe --build -O3 -j 4 --x-assign fast --x-initial fast --noassert \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-UNOPTFLAT \
  --top-module ref_top -Mdir $OUT/obj "${incs[@]}" "${flags[@]}" \
  $( [ -f $HERE/ref_top_$core.sv ] && echo $HERE/ref_top_$core.sv ) "${srcs[@]}" $HERE/ref_sim.cpp -o $OUT/Vref_top > $OUT/build.log 2>&1 \
  || { tail -30 $OUT/build.log; exit 1; }
echo "built $OUT/Vref_top"
