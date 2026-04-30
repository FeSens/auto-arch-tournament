#!/usr/bin/env bash
# One-time toolchain installer for the SystemVerilog auto-architecture researcher.
#
# Installs into .toolchain/ (self-contained). Detects already-installed tools
# on PATH and skips redundant downloads. macOS only.
#
# Acceptance: this script exits 0, then `make lint` reports "no source files".
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_DIR="$REPO_ROOT/.toolchain"
BIN_DIR="$TOOLCHAIN_DIR/bin"
OSS_DIR="$TOOLCHAIN_DIR/oss-cad-suite"

mkdir -p "$BIN_DIR"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This script is macOS-only. Adapt for your OS." >&2
  exit 1
fi

ARCH=$(uname -m)   # arm64 or x86_64
step()      { echo; echo "==> $*"; }
installed() { command -v "$1" &>/dev/null; }

# ── Verilator ─────────────────────────────────────────────────────────────
step "Verilator"
if installed verilator; then
  echo "  $(verilator --version | head -1) — already on PATH"
elif installed brew; then
  brew install --quiet verilator
else
  echo "  ERROR: verilator missing and Homebrew unavailable." >&2
  echo "  Install Homebrew (https://brew.sh) or supply verilator manually." >&2
  exit 1
fi

# ── OSS CAD Suite (yosys, nextpnr-himbaechel, sby, smtbmc, bitwuzla) ──────
step "OSS CAD Suite"
if installed yosys && installed nextpnr-himbaechel && installed sby; then
  echo "  yosys / nextpnr-himbaechel / sby — already on PATH"
elif [ -d "$OSS_DIR/bin" ]; then
  echo "  Found local copy at $OSS_DIR"
else
  echo "  Downloading OSS CAD Suite (~1 GB — takes a few minutes)…"
  if [ "$ARCH" = "arm64" ]; then OSS_ARCH="arm64"; else OSS_ARCH="x64"; fi
  OSS_URL=$(curl -fsSL https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest \
    | grep "browser_download_url" \
    | grep "darwin-${OSS_ARCH}" \
    | head -1 \
    | cut -d'"' -f4)
  if [ -z "$OSS_URL" ]; then
    echo "  ERROR: no OSS CAD Suite release found for darwin-${OSS_ARCH}." >&2
    echo "  See https://github.com/YosysHQ/oss-cad-suite-build/releases" >&2
    exit 1
  fi
  echo "  $OSS_URL"
  curl -fsSL "$OSS_URL" | tar xz -C "$TOOLCHAIN_DIR"
fi

# ── xPack RISC-V GCC (riscv32-unknown-elf symlinks) ───────────────────────
step "RISC-V GCC (xPack)"
if installed riscv32-unknown-elf-gcc; then
  echo "  $(riscv32-unknown-elf-gcc --version | head -1) — already on PATH"
elif [ -f "$BIN_DIR/riscv32-unknown-elf-gcc" ]; then
  echo "  Found local copy in $BIN_DIR"
else
  echo "  Downloading xPack riscv-none-elf-gcc…"
  if [ "$ARCH" = "arm64" ]; then XPACK_ARCH="arm64"; else XPACK_ARCH="x64"; fi
  XPACK_URL=$(curl -fsSL https://api.github.com/repos/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/latest \
    | grep "browser_download_url" \
    | grep "darwin-${XPACK_ARCH}" \
    | grep "\.tar\.gz" \
    | head -1 \
    | cut -d'"' -f4)
  if [ -z "$XPACK_URL" ]; then
    echo "  ERROR: no xPack release found for darwin-${XPACK_ARCH}." >&2
    exit 1
  fi
  echo "  $XPACK_URL"
  curl -fsSL "$XPACK_URL" | tar xz -C "$TOOLCHAIN_DIR"
  XPACK_BIN=$(find "$TOOLCHAIN_DIR" -name "riscv-none-elf-gcc" -type f | head -1 | xargs dirname)
  [ -n "$XPACK_BIN" ] || { echo "  ERROR: xPack binary not found after extraction." >&2; exit 1; }
  for f in "$XPACK_BIN"/riscv-none-elf-*; do
    tool=$(basename "$f")
    ln -sf "$f" "$BIN_DIR/$tool"
    ln -sf "$f" "$BIN_DIR/${tool/riscv-none-elf/riscv32-unknown-elf}"
  done
fi

# ── PATH wiring ───────────────────────────────────────────────────────────
# OSS CAD Suite uses RPATH; sourcing its environment script wires DYLD paths.
if [ -f "$OSS_DIR/environment" ]; then
  # shellcheck disable=SC1091
  source "$OSS_DIR/environment" 2>/dev/null || true
elif [ -d "$OSS_DIR/bin" ]; then
  export PATH="$OSS_DIR/bin:$PATH"
fi
export PATH="$BIN_DIR:$PATH"

# ── Persist PATH (only if we installed something locally) ─────────────────
for profile in "$HOME/.zshrc" "$HOME/.bashrc"; do
  if [ -f "$profile" ]; then
    if [ -d "$OSS_DIR/bin" ] && ! grep -qF "$OSS_DIR/bin" "$profile"; then
      echo "export PATH=\"$OSS_DIR/bin:\$PATH\"" >> "$profile"
      echo "  Added $OSS_DIR/bin to $profile"
    fi
    if [ -d "$BIN_DIR" ] && [ -n "$(ls -A "$BIN_DIR" 2>/dev/null)" ] \
        && ! grep -qF "$BIN_DIR" "$profile"; then
      echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$profile"
      echo "  Added $BIN_DIR to $profile"
    fi
  fi
done

# ── Python deps (cocotb is the test harness; jsonschema/pyyaml/matplotlib drive the orchestrator) ──
step "Python: cocotb cocotb-test pytest jsonschema pyyaml matplotlib"
PIP_PKGS=(cocotb cocotb-test pytest jsonschema pyyaml matplotlib)
if pip install --user --quiet "${PIP_PKGS[@]}" 2>/dev/null; then
  :
elif pip install --break-system-packages --quiet "${PIP_PKGS[@]}" 2>/dev/null; then
  :
else
  pip install --quiet "${PIP_PKGS[@]}"
fi

# ── Sanity check ──────────────────────────────────────────────────────────
step "Verifying tools"
ok=1
for tool in verilator yosys nextpnr-himbaechel sby riscv32-unknown-elf-gcc; do
  if installed "$tool"; then
    echo "  OK   $tool"
  else
    echo "  FAIL $tool — NOT FOUND"
    ok=0
  fi
done

if python3 -c "import cocotb" 2>/dev/null; then
  echo "  OK   cocotb (Python $(python3 --version | awk '{print $2}'))"
else
  echo "  FAIL cocotb — pip install failed"
  ok=0
fi

if [ $ok -eq 0 ]; then
  echo
  echo "Setup incomplete — see errors above." >&2
  exit 1
fi

step "Done"
echo "Next: 'make lint' (should report no source files until phase 1 lands)."
