#!/usr/bin/env bash
# Run riscv-formal checks against the current rtl/*.sv.
# Requires: formal/riscv-formal cloned (manual clone or `git submodule init`).
#
# Stages every rtl/*.sv plus wrapper.sv + the chosen checks config under
# the riscv-formal tree, then runs sby -> bitwuzla via the framework's
# generated makefile. Tallies PASS/FAIL by inspecting each task's
# logfile.txt.
#
# Usage: bash formal/run_all.sh [checks-cfg-path]
#   default: formal/checks.cfg       (fast, ALTOPS, used by orchestrator)
#   deep   : formal/checks-deep.cfg  (no ALTOPS, proves M-ext arithmetic)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RISCV_FORMAL="$SCRIPT_DIR/riscv-formal"
CORE_NAME="auto-arch-researcher"
CORE_DIR="$RISCV_FORMAL/cores/$CORE_NAME"

CHECKS_CFG="${1:-$SCRIPT_DIR/checks.cfg}"
if [ ! -f "$CHECKS_CFG" ]; then
    echo "ERROR: checks.cfg not found at $CHECKS_CFG"
    exit 1
fi

if [ ! -d "$RISCV_FORMAL" ]; then
    echo "ERROR: formal/riscv-formal not found. Clone it:"
    echo "  git clone https://github.com/YosysHQ/riscv-formal $SCRIPT_DIR/riscv-formal"
    exit 1
fi

# OSS CAD Suite for consistent yosys / sby / bitwuzla. Homebrew yosys
# combined with Homebrew bitwuzla has been observed to BrokenPipe inside
# yosys-smtbmc.
if [ -d "$PROJECT_ROOT/.toolchain/oss-cad-suite/bin" ]; then
    export PATH="$PROJECT_ROOT/.toolchain/oss-cad-suite/bin:$PATH"
fi

# Stage rtl + wrapper + the chosen checks config under the framework's
# expected layout. genchecks.py looks for "checks.cfg" by name, so the
# selected config is always copied to that filename in the core dir.
mkdir -p "$CORE_DIR"
cp "$PROJECT_ROOT"/rtl/*.sv     "$CORE_DIR/"
cp "$SCRIPT_DIR/wrapper.sv"     "$CORE_DIR/wrapper.sv"
cp "$CHECKS_CFG"                "$CORE_DIR/checks.cfg"

# genchecks.py expects @basedir@ = $RISCV_FORMAL, @core@ = $CORE_NAME.
cd "$CORE_DIR"
rm -rf checks/
python3 ../../checks/genchecks.py > /dev/null
cd checks

JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
make -j"$JOBS" -f makefile 2>&1 | grep -E "^(make|SBY|yosys|==)" || true

shopt -s nullglob
PASS=0; FAIL=0; FAILED=()
for sby_file in *.sby; do
    name="${sby_file%.sby}"
    if grep -q "DONE (PASS" "$name/logfile.txt" 2>/dev/null; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1)); FAILED+=("$name")
    fi
done
TOTAL=$((PASS+FAIL))
if [ $TOTAL -eq 0 ]; then
    FAIL=1
    FAILED+=("no_checks_generated")
fi

echo ""
echo "Formal: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
    echo "Failed: ${FAILED[*]}"
    echo "Logs in: $CORE_DIR/checks/<check>/logfile.txt"
fi
[ $FAIL -eq 0 ]
