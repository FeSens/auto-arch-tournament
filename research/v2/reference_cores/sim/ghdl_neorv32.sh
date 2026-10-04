#!/bin/bash
# NEORV32 CPU + flat shim -> one Verilog file for Verilator (ghdl --synth).
set -euo pipefail
export PATH=/opt/hwe-toolchain/oss-cad-suite/bin:$PATH
D=$HOME/refcores/sim/neorv32_ghdl; R=$HOME/refcores/neorv32/rtl/core
mkdir -p $D && cd $D && rm -f *.cf
for n in package sys prim cpu_decompressor cpu_frontend cpu_control cpu_hwtrig cpu_counters \
         cpu_regfile cpu_alu_shifter cpu_alu_muldiv cpu_alu_bitmanip cpu_alu_fpu cpu_alu_cond \
         cpu_alu_crypto cpu_alu_cfu cpu_alu cpu_lsu cpu_pmp cpu_trace cpu; do
  ghdl -a --std=08 --work=neorv32 $R/neorv32_$n.vhd
done
ghdl -a --std=08 "$(dirname "$(readlink -f "$0")")/../benches/neorv32_cpu_flat.vhd"
ghdl --synth --std=08 --out=verilog neorv32_cpu_flat > neorv32_cpu_flat.v
