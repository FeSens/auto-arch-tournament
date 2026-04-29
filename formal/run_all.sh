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

# Path-parametrization. Defaults preserve the legacy single-rtl/ behavior.
RTL_DIR="${RTL_DIR:-rtl}"
CORE_NAME="${CORE_NAME:-auto-arch-researcher}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RISCV_FORMAL="$SCRIPT_DIR/riscv-formal"
CORE_DIR="$RISCV_FORMAL/cores/$CORE_NAME"
# Full output capture. Everything genchecks + make print lands here, so a
# silent crash inside genchecks or a yosys error that doesn't match the
# stdout grep filter is still recoverable post-mortem.
LOG="$SCRIPT_DIR/last_run.log"

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

# Truncate the run log; genchecks + make are tee'd here in full.
: > "$LOG"

# Stage rtl + wrapper + the chosen checks config under the framework's
# expected layout. genchecks.py looks for "checks.cfg" by name, so the
# selected config is always copied to that filename in the core dir.
mkdir -p "$CORE_DIR"
# Clear stale .sv files first. Without this, a hypothesis that renames or
# deletes a module in rtl/ leaves a ghost copy in $CORE_DIR from the
# previous run, and genchecks/yosys silently picks up the old file
# instead of the new one. CLAUDE.md explicitly grants hypotheses the
# right to rename/delete files in rtl/, so this cleanup is required.
rm -f "$CORE_DIR"/*.sv
cp "$PROJECT_ROOT"/$RTL_DIR/*.sv "$CORE_DIR/"
cp "$SCRIPT_DIR/wrapper.sv"     "$CORE_DIR/wrapper.sv"

# Stage checks.cfg with [verilog-files] auto-derived from actual rtl/
# contents instead of the cfg's hardcoded list. The shipped checks.cfg
# enumerates the V0 baseline filenames; CLAUDE.md grants hypotheses the
# right to add new modules, split a stage into multiple files, or rename
# files in rtl/. Hardcoding silently fails on those restructurings (or
# elaborates a stale ghost). Strip the original [verilog-files] section
# and rebuild from the glob, with core_pkg.sv first and wrapper.sv last.
STAGED_CFG="$CORE_DIR/checks.cfg"
awk '/^\[verilog-files\]/{exit} {print}' "$CHECKS_CFG" > "$STAGED_CFG"
{
    echo "[verilog-files]"
    [ -f "$CORE_DIR/core_pkg.sv" ] && \
        echo "@basedir@/cores/@core@/core_pkg.sv"
    for f in "$CORE_DIR"/*.sv; do
        name="$(basename "$f")"
        [ "$name" = "core_pkg.sv" ] && continue
        [ "$name" = "wrapper.sv" ] && continue
        echo "@basedir@/cores/@core@/$name"
    done
    echo "@basedir@/cores/@core@/wrapper.sv"
} >> "$STAGED_CFG"

# genchecks.py expects @basedir@ = $RISCV_FORMAL, @core@ = $CORE_NAME.
cd "$CORE_DIR"
rm -rf checks/
echo "=== genchecks ===" | tee -a "$LOG"
python3 ../../checks/genchecks.py >> "$LOG" 2>&1
cd checks

JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
echo "=== make -j$JOBS -k ===" | tee -a "$LOG"
# Tee full output to LOG; show filtered progress on stdout. `-k` keeps
# going past per-check errors so the .sby tally below sees every result
# (NRET=2 means a few `_ch1` checks may PREUNSAT-error on single-issue
# cores; without -k make stops on first error and 95+ checks never run,
# producing a misleading failure list of unbuilt directories).
make -j"$JOBS" -k -f makefile 2>&1 \
    | tee -a "$LOG" \
    | grep -E "^(make|SBY|yosys|==|ERROR)" || true

shopt -s nullglob
PASS=0; FAIL=0; FAILED=()
for sby_file in *.sby; do
    name="${sby_file%.sby}"
    log="$name/logfile.txt"
    if grep -q "DONE (PASS" "$log" 2>/dev/null; then
        PASS=$((PASS+1))
    elif [[ "$name" == *_ch1 ]] && grep -q "Status: PREUNSAT" "$log" 2>/dev/null; then
        # Vacuous pass on channel-1 checks. NRET=2 contract: when a
        # single-issue hypothesis ties io_rvfi_valid_1 to 0, the per-channel
        # BMC's assumption (rvfi_valid_1=1) is unsatisfiable, and SBY
        # reports Status: PREUNSAT (rc=16). The property holds vacuously
        # over the empty set of ch1-valid traces — a legitimate pass.
        # Dual-issue hypotheses make the assumption satisfiable, so this
        # branch never matches and the regular DONE (PASS branch covers it.
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
    # Surface the FIRST failing check's logfile tail. tools/eval/formal.py
    # captures this script's stdout/stderr into formal['detail'] and the
    # orchestrator now records that in experiments/log.jsonl, so what we
    # print here is what shows up as the diagnostic for the failed run.
    first="${FAILED[0]}"
    if [ -f "$first/logfile.txt" ]; then
        echo ""
        echo "--- $first/logfile.txt (last 30 lines) ---"
        tail -30 "$first/logfile.txt"
    fi
    echo ""
    echo "Full run log: $LOG"
    echo "Per-check logs in: $CORE_DIR/checks/<check>/logfile.txt"
fi
[ $FAIL -eq 0 ]
