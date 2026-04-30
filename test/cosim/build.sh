#!/usr/bin/env bash
# Build the Verilator-based cosim binary that drives `core` against an ELF
# program. Produces $OBJ_DIR/cosim_sim (default: test/cosim/obj_dir/cosim_sim).
#
# RTL_DIR (default: rtl/) is globbed dynamically (with core_pkg.sv forced
# first because its compilation-unit-scope typedefs and localparams must be
# visible before any module references them). Hypotheses are allowed to add,
# rename, or delete files inside rtl/, so a hardcoded file list would
# silently break restructuring hypotheses.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COSIM_DIR="$REPO_ROOT/test/cosim"
if [ -z "${RTL_DIR:-}" ] || [ -z "${OBJ_DIR:-}" ]; then
  echo "ERROR: test/cosim/build.sh requires RTL_DIR and OBJ_DIR env vars." >&2
  echo "  Example: RTL_DIR=cores/v1/rtl OBJ_DIR=cores/v1/obj_dir bash test/cosim/build.sh" >&2
  exit 2
fi

# Ensure OSS CAD Suite tools are on PATH for non-interactive shells.
TOOLCHAIN="$REPO_ROOT/.toolchain"
if [ -d "$TOOLCHAIN/oss-cad-suite/bin" ]; then
  export PATH="$TOOLCHAIN/oss-cad-suite/bin:$PATH"
fi

mkdir -p "$OBJ_DIR"

# Glob $RTL_DIR/*.sv. core_pkg.sv first; the rest in a stable lexicographic
# order (modulo case-insensitive sort, which Verilator/gcc don't care
# about). If core_pkg.sv is missing the build will catch that downstream
# via undefined-typedef errors.
RTL_FILES=()
[ -f "$RTL_DIR/core_pkg.sv" ] && RTL_FILES+=("$RTL_DIR/core_pkg.sv")
for f in "$RTL_DIR"/*.sv; do
  [ "$(basename "$f")" = "core_pkg.sv" ] && continue
  RTL_FILES+=("$f")
done

if [ ${#RTL_FILES[@]} -eq 0 ]; then
  echo "ERROR: no rtl/*.sv files found." >&2
  exit 1
fi

verilator --cc --exe --build \
  -Mdir "$OBJ_DIR" \
  "+incdir+$RTL_DIR" \
  --top-module core \
  -Wall -Wno-fatal -Wno-style \
  "${RTL_FILES[@]}" \
  "$COSIM_DIR/main.cpp" \
  -o cosim_sim

echo "Built: $OBJ_DIR/cosim_sim"
