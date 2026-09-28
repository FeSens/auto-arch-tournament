#!/usr/bin/env bash
# Run riscv-formal checks against the current $RTL_DIR/*.sv.
# Requires: formal/riscv-formal cloned (manual clone or `git submodule init`).
#
# Stages every $RTL_DIR/*.sv plus wrapper.sv + the chosen checks config under
# the riscv-formal tree, then runs sby -> bitwuzla via the framework's
# generated makefile. Tallies PASS/FAIL by inspecting each task's
# logfile.txt.
#
# Usage: bash formal/run_all.sh [checks-cfg-path]
#   default: formal/checks.cfg       (fast, ALTOPS, used by orchestrator)
#   deep   : formal/checks-deep.cfg  (no ALTOPS, proves M-ext arithmetic)
#
# Env vars (orchestrator-driven, override $1 and defaults):
#   WRAPPER     — path to wrapper SV (default formal/wrapper.sv)
#   CHECKS_CFG  — path to checks config (default formal/checks.cfg)
# When BOTH are unset, the script auto-detects nret from
# cores/$CORE_NAME/core.yaml: nret=1 routes to wrapper_si.sv +
# checks_si.cfg; nret=2 (or absent) uses the defaults. Agents
# invoking `bash formal/run_all.sh` directly therefore get the
# right wrapper without needing to know the env-var plumbing.
set -e

if [ -z "${RTL_DIR:-}" ] || [ -z "${CORE_NAME:-}" ]; then
  echo "ERROR: formal/run_all.sh requires RTL_DIR and CORE_NAME env vars." >&2
  echo "  Example: RTL_DIR=cores/v1/rtl CORE_NAME=v1 bash formal/run_all.sh formal/checks.cfg" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RISCV_FORMAL="$SCRIPT_DIR/riscv-formal"
# Per-invocation work dir + log, unique among every process sharing this
# riscv-formal checkout (the K concurrent agents of a run share it through
# their worktrees' symlink). The name used to be "$CORE_NAME-$$", but an
# agent's sandboxed shell runs in its own PID namespace where $$ is 2 or 3
# for every agent, so siblings wrote into one dir and wiped each other's
# checks mid-SBY (V2 incident 03). mktemp gives a unique name instead.
# FORMAL_WORK_ID pins the suffix so tools/eval/formal.py can remove exactly
# its own dir afterwards. genchecks.py derives @core@ from the dir's
# basename (genchecks.py:39), so @core@ = "$CORE_NAME-<suffix>".
mkdir -p "$RISCV_FORMAL/cores"
if [ -n "${FORMAL_WORK_ID:-}" ]; then
    if [[ ! "$FORMAL_WORK_ID" =~ ^[A-Za-z][A-Za-z0-9]*$ ]]; then
        echo "ERROR: FORMAL_WORK_ID must be a letter followed by letters/digits" >&2
        exit 2
    fi
    CORE_DIR="$RISCV_FORMAL/cores/$CORE_NAME-$FORMAL_WORK_ID"
    mkdir "$CORE_DIR"
else
    # mktemp picks the name; mkdir creates it (atomic, fails if it exists)
    # so the dir gets the usual umask and default-ACL permissions, which
    # `mktemp -d` would replace with 0700.
    CORE_DIR=
    for _ in 1 2 3 4 5 6 7 8; do
        try="$(mktemp -u "$RISCV_FORMAL/cores/$CORE_NAME-wXXXXXXXX")"
        if mkdir "$try" 2>/dev/null; then CORE_DIR="$try"; break; fi
    done
    if [ -z "$CORE_DIR" ]; then
        echo "ERROR: could not create a work dir under $RISCV_FORMAL/cores" >&2
        exit 1
    fi
fi
WORK_ID="${CORE_DIR##*-}"
LOG="$SCRIPT_DIR/last_run-$WORK_ID.log"

# Hold a lock on the work dir for this run's lifetime. The reaper below
# only removes dirs whose lock nobody holds; flock works across users and
# PID namespaces, unlike the old `kill -0 <pid>` test (from inside a
# sandbox every outside PID looks dead). Without flock(1), nothing is reaped.
HAVE_FLOCK=
if command -v flock >/dev/null 2>&1; then
    exec 9>"$CORE_DIR/.owner.lock"
    flock 9
    HAVE_FLOCK=1
fi

# Auto-detect single-issue cores from core.yaml when WRAPPER + CHECKS_CFG
# are both unset and $1 (checks-cfg-path) wasn't given either. Explicit
# env vars or $1 still win. Uses python3 to parse YAML robustly — bash
# grep would mis-handle quoted/indented variants and break on the next
# yaml schema bump.
CORE_YAML="$PROJECT_ROOT/cores/$CORE_NAME/core.yaml"
if [ -z "${WRAPPER:-}" ] && [ -z "${CHECKS_CFG:-}" ] && [ -z "${1:-}" ] \
   && [ -f "$CORE_YAML" ]; then
    # Pass the path via env var so the python literal stays free of any
    # bash-substituted strings that could break on quoting / spaces.
    NRET=$(CORE_YAML="$CORE_YAML" python3 -c '
import os, yaml
try:
    d = yaml.safe_load(open(os.environ["CORE_YAML"]).read()) or {}
    print(int(d.get("nret", 2)))
except Exception:
    print(2)
' 2>/dev/null)
    if [ "$NRET" = "1" ]; then
        WRAPPER="$SCRIPT_DIR/wrapper_si.sv"
        CHECKS_CFG="$SCRIPT_DIR/checks_si.cfg"
        echo "[run_all.sh] auto-detected nret=1 from $CORE_YAML; using wrapper_si.sv + checks_si.cfg"
    fi
fi

CHECKS_CFG="${CHECKS_CFG:-${1:-$SCRIPT_DIR/checks.cfg}}"
WRAPPER="${WRAPPER:-$SCRIPT_DIR/wrapper.sv}"
if [ ! -f "$CHECKS_CFG" ]; then
    echo "ERROR: checks.cfg not found at $CHECKS_CFG"
    exit 1
fi
if [ ! -f "$WRAPPER" ]; then
    echo "ERROR: wrapper not found at $WRAPPER"
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

# Reap work dirs (and their logs) left by runs that have ended: the lock
# file exists, is over 10 minutes old, and nobody holds it. A dir with no
# lock file (older script versions, or one created a moment ago and not yet
# locked) is never touched. Bounds disk growth from agents that invoke
# run_all.sh dozens of times.
shopt -s nullglob
if [ -n "$HAVE_FLOCK" ]; then
    for stale in "$RISCV_FORMAL/cores/$CORE_NAME-"*; do
        [ "$stale" = "$CORE_DIR" ] && continue
        lock="$stale/.owner.lock"
        [ -f "$lock" ] || continue
        [ -n "$(find "$lock" -mmin +10 2>/dev/null)" ] || continue
        if flock -n "$lock" true 2>/dev/null; then
            rm -rf "$stale"
            rm -f "$SCRIPT_DIR/last_run-${stale##*-}.log"
        fi
    done
fi
shopt -u nullglob

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
cp "$PROJECT_ROOT/$RTL_DIR"/*.sv "$CORE_DIR/"
cp "$WRAPPER"                   "$CORE_DIR/wrapper.sv"

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

# genchecks.py derives @core@ from the cwd's basename (genchecks.py:39),
# so cd-ing into $CORE_DIR (= $RISCV_FORMAL/cores/$CORE_NAME-<suffix>)
# yields @core@="$CORE_NAME-<suffix>". The [verilog-files] lines we just
# wrote reference that @core@, so all paths resolve into this private dir.
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
