#!/bin/bash
# sv2v conversion of the pinned Ibex plus one bench (as in ibex syn/syn_yosys.sh)
set -euo pipefail
cfg=$1
I=$HOME/refcores/ibex-e4bcf749
B=/home/bench/auto-arch-tournament/research/v2/reference_cores/benches
OUT=$HOME/refcores/gen/ibex_${cfg}_bench.v
mkdir -p $HOME/refcores/gen
P=$I/vendor/lowrisc_ip/ip
RTL=$(ls $I/rtl/*.sv | grep -v -E '_pkg.sv$|ibex_tracer.sv|ibex_top_tracing.sv')
$HOME/refcores/tools/sv2v-Linux/sv2v --define=SYNTHESIS --define=YOSYS \
  $I/rtl/ibex_pkg.sv \
  $P/prim_generic/rtl/prim_ram_1p_pkg.sv $P/prim/rtl/prim_secded_pkg.sv \
  $P/prim/rtl/prim_util_pkg.sv $P/prim/rtl/prim_count_pkg.sv $P/prim/rtl/prim_cipher_pkg.sv \
  -I$P/prim/rtl -I$I/vendor/lowrisc_ip/dv/sv/dv_utils \
  $RTL \
  $P/prim/rtl/prim_count.sv $P/prim/rtl/prim_secded_inv_39_32_dec.sv \
  $P/prim/rtl/prim_secded_inv_39_32_enc.sv $P/prim/rtl/prim_lfsr.sv \
  $P/prim_generic/rtl/prim_and2.sv $P/prim_generic/rtl/prim_buf.sv \
  $P/prim_generic/rtl/prim_clock_mux2.sv $P/prim_generic/rtl/prim_flop.sv \
  $B/prim_clock_gating_passthrough.sv \
  $B/ibex_${cfg}_bench.src.sv > $OUT
sed -i -e 's/\bprim_and2\b/prim_generic_and2/g' -e 's/\bprim_buf\b/prim_generic_buf/g' \
  -e 's/\bprim_clock_mux2\b/prim_generic_clock_mux2/g' -e 's/\bprim_flop\b/prim_generic_flop/g' $OUT
grep -c '^module' $OUT
