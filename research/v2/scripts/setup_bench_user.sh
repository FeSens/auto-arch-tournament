#!/usr/bin/env bash
# One-time setup for HWE Bench V2 agent isolation. Run from the operator
# account:   sudo bash research/v2/scripts/setup_bench_user.sh
#
# Design: the benchmark runner (which holds the hidden held-out kernels and
# every published result) keeps running as the operator. Only the agent CLIs
# run as the unprivileged user `hwebench`, which
#   - has its own primary group (`hwebench`), is not in `staff`, and so cannot
#     read the operator's home (drwxr-x--- group staff);
#   - shares exactly one directory with the operator: /Users/Shared/hwebench
#     (run clones, the toolchain copy, the pinned CLI binaries), group
#     `hwebench`, setgid, group-writable.
# Every CLI is subject to the same operating-system boundary, whatever its
# own sandbox allows (V1: Codex agents could read any file; Claude agents
# could not).
#
# It also lets the operator start processes as hwebench (never as root)
# without a password, so the runner can launch agents unattended.
#
# Afterwards, log both CLIs in once (see the end of this script).
set -euo pipefail

OPERATOR=${SUDO_USER:?run with sudo from the operator account}
OP_HOME=$(dscl . -read "/Users/$OPERATOR" NFSHomeDirectory | awk '{print $2}')
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
U=hwebench
SHARED=/Users/Shared/hwebench
# The EDA/compiler toolchain the operator's PATH uses (override with
# sudo TOOLCHAIN=/path bash ...).
TOOLCHAIN=${TOOLCHAIN:-$(dirname "$REPO")/riscv-autoarch/.toolchain}
[ -x "$TOOLCHAIN/oss-cad-suite/bin/yosys" ] || { echo "no toolchain at $TOOLCHAIN"; exit 1; }
TOOLCHAIN=$(cd "$TOOLCHAIN" && pwd -P)
PY=$(sudo -u "$OPERATOR" /bin/zsh -lic 'command -v python3' 2>/dev/null | tail -1)
PY=${PY:-/opt/homebrew/Caskroom/miniconda/base/bin/python3}
PYVER=$("$PY" -c 'import sys; print(f"python{sys.version_info[0]}.{sys.version_info[1]}")')

# 1. Group and user.
if ! dscl . -read "/Groups/$U" >/dev/null 2>&1; then
  dseditgroup -o create -r "HWE Bench" "$U"
fi
GID=$(dscl . -read "/Groups/$U" PrimaryGroupID | awk '{print $2}')
if ! id "$U" >/dev/null 2>&1; then
  sysadminctl -addUser "$U" -fullName "HWE Bench agent" -password "$(openssl rand -hex 24)" -home "/Users/$U"
  createhomedir -c -u "$U" >/dev/null
fi
dscl . -create "/Users/$U" PrimaryGroupID "$GID"
dseditgroup -o edit -d "$U" -t user staff 2>/dev/null || true
dseditgroup -o edit -a "$U" -t user "$U"
dseditgroup -o edit -a "$OPERATOR" -t user "$U"
chown -R "$U:$U" "/Users/$U"
chmod 700 "/Users/$U"

# 2. Shared directory: clones, toolchain, CLI binaries, and the pieces of
#    the operator's ~/.local the agents' self-checks use (sby, cocotb).
mkdir -p "$SHARED"/{clones,bin,toolchain} "$SHARED"/local/{bin,lib,share}
rsync -a --delete "$TOOLCHAIN/" "$SHARED/toolchain/"
# Absolute links into the operator's copy (bin/riscv32-unknown-elf-gcc &
# co.) must point into the shared copy.
find "$SHARED/toolchain" -type l | while read -r l; do
  t=$(readlink "$l")
  case "$t" in "$TOOLCHAIN"/*) ln -sfn "$SHARED/toolchain${t#"$TOOLCHAIN"}" "$l" ;; esac
done
rsync -a --delete "$OP_HOME/.local/lib/$PYVER/" "$SHARED/local/lib/$PYVER/"
rsync -a --delete "$OP_HOME/.local/share/yosys/" "$SHARED/local/share/yosys/"
for b in sby cocotb-config cocotb-run cocotb-clean find_libpython; do
  if [ -e "$OP_HOME/.local/bin/$b" ]; then install -m 755 "$OP_HOME/.local/bin/$b" "$SHARED/local/bin/$b"; fi
done
rsync -a --delete "$OP_HOME/.codex/packages/standalone/current/" "$SHARED/bin/codex-pkg/"
CLAUDE_BIN=$(readlink "$OP_HOME/.local/bin/claude")
install -m 755 "$CLAUDE_BIN" "$SHARED/bin/claude"
ln -sfn "$SHARED/bin/codex-pkg/bin/codex" "$SHARED/bin/codex"
basename "$CLAUDE_BIN" > "$SHARED/bin/claude.version"
cp "$SHARED/bin/codex-pkg/codex-package.json" "$SHARED/bin/codex.version.json"
chown -R "$OPERATOR:$U" "$SHARED"
chmod -R g+rwX,o-rwx "$SHARED"
find "$SHARED" -type d -exec chmod g+s {} +
chmod -R go-w "$SHARED/bin" "$SHARED/toolchain" "$SHARED/local"   # agents cannot swap tools
# Clones: both accounts get full control of everything created inside,
# independent of umask or of whether a session has picked up the new group.
PERMS="list,add_file,search,delete,add_subdirectory,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit"
chmod -R -N "$SHARED/clones"
chmod +a "user:$OPERATOR allow $PERMS" "$SHARED/clones"
chmod +a "user:$U allow $PERMS" "$SHARED/clones"

# 3. Operator may run processes as hwebench (not root) without a password.
echo "$OPERATOR ALL=($U) NOPASSWD: ALL" > /etc/sudoers.d/hwebench
chmod 440 /etc/sudoers.d/hwebench
visudo -cf /etc/sudoers.d/hwebench

# 4. Verify the boundary.
fail=0
for p in "$OP_HOME" "$REPO/bench/LEADERBOARD.md" "$REPO/bench/holdout"; do
  if sudo -u "$U" test -r "$p"; then echo "FAIL: $U can read $p"; fail=1; fi
done
sudo -u "$U" test -w "$SHARED/clones" || { echo "FAIL: $U cannot write $SHARED/clones"; fail=1; }
# The same PATH tools/bench/runner.py AgentUser.path gives the agents.
AGENT_PATH="$SHARED/bin:$SHARED/local/bin:$SHARED/toolchain/oss-cad-suite/bin:$SHARED/toolchain/bin:$(dirname "$PY"):/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
CHECK_LOG="$SHARED/setup-check.log"
if ! sudo -u "$U" /usr/bin/env -i HOME="/Users/$U" PATH="$AGENT_PATH" PYTHONUSERBASE="$SHARED/local" \
     /bin/sh -c 'yosys -V && verilator --version && nextpnr-himbaechel --version && sby --help >/dev/null &&
                 bitwuzla --version && riscv32-unknown-elf-gcc --version &&
                 python3 -c "import cocotb_tools.runner, pytest" && codex --version && claude --version' \
     >"$CHECK_LOG" 2>&1; then
  echo "FAIL: toolchain not usable by $U; see $CHECK_LOG"; fail=1
fi
[ "$fail" = 0 ] || exit 1

cat <<EOF
OK: $U cannot read $OP_HOME; shared dir $SHARED is ready.
Pinned CLIs: claude $(cat "$SHARED/bin/claude.version"), codex $(grep -o '"version"[^,}]*' "$SHARED/bin/codex.version.json")

Two logins remain (once):
  1. Codex, as $U (prints a code to enter in your browser):
       sudo -iu $U $SHARED/bin/codex login --device-auth
  2. Claude, as yourself (prints a long-lived token):
       claude setup-token
     then add it to ~/.bench-keys.env (readable only by you):
       echo 'CLAUDE_CODE_OAUTH_TOKEN=<token>' >> ~/.bench-keys.env && chmod 600 ~/.bench-keys.env
EOF
