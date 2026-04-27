#!/usr/bin/env bash
# Build the Verilator-based cosim binary that drives `core` against an ELF
# program. Produces test/cosim/obj_dir/cosim_sim.
#
# The wrapper main.cpp drives io_imemAddr / io_imemData and io_dmem* by
# port name; the existing port shape comes from rtl/core.sv directly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COSIM_DIR="$REPO_ROOT/test/cosim"
OBJ_DIR="$COSIM_DIR/obj_dir"

# Ensure OSS CAD Suite tools are on PATH for non-interactive shells (the
# parent Makefile already does this, but the script must work standalone).
TOOLCHAIN="$REPO_ROOT/.toolchain"
if [ -d "$TOOLCHAIN/oss-cad-suite/bin" ]; then
  export PATH="$TOOLCHAIN/oss-cad-suite/bin:$PATH"
fi

mkdir -p "$OBJ_DIR"

# Build with --build (verilator drives the C++ compiler itself).
verilator --cc --exe --build \
  -Mdir "$OBJ_DIR" \
  --top-module core \
  -Wall -Wno-fatal -Wno-style \
  "$REPO_ROOT"/rtl/core_pkg.sv \
  "$REPO_ROOT"/rtl/alu.sv \
  "$REPO_ROOT"/rtl/decoder.sv \
  "$REPO_ROOT"/rtl/imm_gen.sv \
  "$REPO_ROOT"/rtl/reg_file.sv \
  "$REPO_ROOT"/rtl/if_stage.sv \
  "$REPO_ROOT"/rtl/id_stage.sv \
  "$REPO_ROOT"/rtl/ex_stage.sv \
  "$REPO_ROOT"/rtl/mem_stage.sv \
  "$REPO_ROOT"/rtl/wb_stage.sv \
  "$REPO_ROOT"/rtl/hazard_unit.sv \
  "$REPO_ROOT"/rtl/forward_unit.sv \
  "$REPO_ROOT"/rtl/core.sv \
  "$COSIM_DIR/main.cpp" \
  -o cosim_sim

echo "Built: $OBJ_DIR/cosim_sim"
