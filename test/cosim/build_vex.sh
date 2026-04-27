#!/usr/bin/env bash
# Build the VexRiscv-binary-compatible cosim. Sister to build.sh but
# uses test/cosim/vex_main.cpp (different memory map + MMIO) and emits
# test/cosim/obj_dir_vex/vex_sim.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COSIM_DIR="$REPO_ROOT/test/cosim"
OBJ_DIR="$COSIM_DIR/obj_dir_vex"
RTL_DIR="$REPO_ROOT/rtl"

TOOLCHAIN="$REPO_ROOT/.toolchain"
if [ -d "$TOOLCHAIN/oss-cad-suite/bin" ]; then
  export PATH="$TOOLCHAIN/oss-cad-suite/bin:$PATH"
fi

mkdir -p "$OBJ_DIR"

RTL_FILES=()
[ -f "$RTL_DIR/core_pkg.sv" ] && RTL_FILES+=("$RTL_DIR/core_pkg.sv")
for f in "$RTL_DIR"/*.sv; do
  [ "$(basename "$f")" = "core_pkg.sv" ] && continue
  RTL_FILES+=("$f")
done

verilator --cc --exe --build \
  -Mdir "$OBJ_DIR" \
  --top-module core \
  -Wall -Wno-fatal -Wno-style \
  "${RTL_FILES[@]}" \
  "$COSIM_DIR/vex_main.cpp" \
  -o vex_sim

echo "Built: $OBJ_DIR/vex_sim"
