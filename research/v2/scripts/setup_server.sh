#!/usr/bin/env bash
# One-time setup of the HWE Bench V2 run host (Linux). Run as root:
#   bash research/v2/scripts/setup_server.sh
#
# Same design as setup_bench_user.sh (macOS): the runner runs as the
# operator account `bench`; only the agent CLIs run, as one of a pool of
# agent accounts (hwebench, hwebench2, hwebench3: one per concurrent run,
# so runs cannot read each other), none of which can read the operator's
# home (held-out kernels, results). They share /srv/hwebench: run clones
# (each clone's ACL admits only the account running it), per-run homes,
# the pinned toolchain (/opt/hwe-toolchain, read-only), a Python venv with
# the test dependencies, and the pinned CLI binaries.
#
# Toolchain and CLI versions match the Mac that produced the V2 pilot
# numbers: oss-cad-suite 2026-04-24 (Yosys 0.64+149), xPack RISC-V GCC
# 15.2.0-1, Claude Code 2.1.283, Codex 0.156.1.
set -euo pipefail

OP=bench
U=hwebench
POOL="hwebench hwebench2 hwebench3"
SHARED=/srv/hwebench
TC=/opt/hwe-toolchain
CLAUDE_VERSION=2.1.283
CODEX_VERSION=0.156.1
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

# 0. GNU coreutils. Ubuntu 26.04 defaults to the Rust uutils (tail, head,
#    sort, ...), which reject GNU usages like `tail -5 a b` that the harness
#    scripts and the agents' shell habits rely on.
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --allow-remove-essential coreutils-from-gnu coreutils-from-uutils- >/dev/null

# 1. Accounts. Neither is in the other's primary group; homes are private.
id "$OP" >/dev/null 2>&1 || useradd -m -s /bin/bash "$OP"
for a in $POOL; do id "$a" >/dev/null 2>&1 || useradd -m -U -s /bin/bash "$a"; done
chmod 750 "/home/$OP"
# The orchestrator commits in every clone; a neutral identity, not a person's.
for a in "$OP" $POOL; do
  sudo -iu "$a" git config --global user.name "HWE Bench"
  sudo -iu "$a" git config --global user.email "hwe-bench@localhost"
done
for a in $POOL; do
  chmod 700 "/home/$a"
  getent group "$OP" | grep -qw "$a" && { echo "FAIL: $a is in group $OP"; exit 1; }
done

# 2. Toolchain (pinned releases; the gcc tarball is checksum-verified).
if [ ! -x "$TC/oss-cad-suite/bin/yosys" ]; then
  mkdir -p "$TC/bin"; cd "$TC"
  curl -fsSL -o oss.tgz https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-04-24/oss-cad-suite-linux-x64-20260424.tgz
  tar xzf oss.tgz && rm oss.tgz
  X=xpack-riscv-none-elf-gcc-15.2.0-1-linux-x64.tar.gz
  curl -fsSL -o "$X" "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v15.2.0-1/$X"
  curl -fsSL -o "$X.sha" "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v15.2.0-1/$X.sha"
  echo "$(cut -d' ' -f1 "$X.sha")  $X" | sha256sum -c
  tar xzf "$X" && rm "$X" "$X.sha"
  for f in xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-*; do
    n=$(basename "$f"); ln -sf "$TC/$f" "bin/${n/riscv-none-elf/riscv32-unknown-elf}"
  done
fi
chmod -R go-w "$TC"

# 3. Shared directory.
mkdir -p "$SHARED"/{clones,bin}
ln -sfn "$TC" "$SHARED/toolchain"
# Python 3.13.12 as on the Mac (cocotb 2.0.1 rejects the distro's 3.14),
# installed by uv under /opt/hwe-python, readable by both accounts.
if [ ! -x "$SHARED/venv/bin/python3" ]; then
  command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh >/dev/null
  export UV_PYTHON_INSTALL_DIR=/opt/hwe-python
  uv python install 3.13.12
  uv venv -q --python 3.13.12 "$SHARED/venv"
  uv pip install -q --python "$SHARED/venv/bin/python" cocotb==2.0.1 cocotb-test==0.2.6 \
      pytest==9.0.3 click==8.2.1 find_libpython psutil==7.2.2 pyyaml==6.0.3 \
      jsonschema==4.26.0 matplotlib Verilog_VCD
  chmod -R go-w,a+rX /opt/hwe-python
fi
# python-build-standalone marks libpython as needing an executable stack;
# glibc >= 2.41 then refuses to dlopen it, which breaks every cocotb test
# (Verilator loads libpython through the VPI). It does not need one.
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq patchelf >/dev/null
for lib in /opt/hwe-python/cpython-3.13.12-*/lib/libpython3.13.so.1.0; do
  patchelf --clear-execstack "$lib"
done

# 4. Pinned CLIs.
if [ ! -x "$SHARED/bin/claude" ]; then
  curl -fsSL https://claude.ai/install.sh | bash -s "$CLAUDE_VERSION" >/dev/null
  install -m 755 "$(readlink -f /root/.local/bin/claude)" "$SHARED/bin/claude"
  echo "$CLAUDE_VERSION" > "$SHARED/bin/claude.version"
fi
if [ ! -x "$SHARED/bin/codex" ]; then
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/p.tgz" "https://github.com/openai/codex/releases/download/rust-v$CODEX_VERSION/codex-package-x86_64-unknown-linux-musl.tar.gz"
  mkdir -p "$SHARED/bin/codex-pkg" && tar xzf "$tmp/p.tgz" -C "$SHARED/bin/codex-pkg" && rm -rf "$tmp"
  ln -sfn "$(find "$SHARED/bin/codex-pkg" -path '*bin/codex' -type f | head -1)" "$SHARED/bin/codex"
  cp "$(find "$SHARED/bin/codex-pkg" -name codex-package.json | head -1)" "$SHARED/bin/codex.version.json" 2>/dev/null \
    || echo "{\"version\": \"$CODEX_VERSION\"}" > "$SHARED/bin/codex.version.json"
fi

ln -sfn "$SHARED/bin/claude" /usr/local/bin/claude
ln -sfn "$SHARED/bin/codex" /usr/local/bin/codex

# 4b. Vendor FPGA flow (V2 timing): Gowin EDA Education 1.9.11.03, plus the
#     X/GL libraries gw_sh links against (fetched as .debs, not installed).
if [ ! -x /opt/gowin/IDE/bin/gw_sh ]; then
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/g.tgz" https://cdn.gowinsemi.com.cn/Gowin_V1.9.11.03_Education_Linux.tar.gz
  echo "6fd392f7473b24d847b6f8ebdc7a185c591826ba35d8d0e517961030d446f9f7  $tmp/g.tgz" | sha256sum -c
  mkdir -p /opt/gowin/deps/debs && tar xzf "$tmp/g.tgz" -C /opt/gowin && rm -rf "$tmp"
  (cd /opt/gowin/deps/debs && apt-get download libasound2t64 libfontconfig1 libgl1 libglvnd0 libglx0 \
     libglx-mesa0 libnspr4 libnss3 libx11-6 libx11-xcb1 libxcomposite1 libxdamage1 libxfixes3 \
     libxrandr2 libxtst6 libxcb1 libxau6 libxdmcp6 libxext6 libxrender1 libxi6 libfreetype6 \
     libexpat1 libpng16-16t64 libbrotli1 && for d in *.deb; do dpkg-deb -x "$d" ../root; done)
fi
chown -R root:root /opt/gowin; chmod -R go-w,a+rX /opt/gowin
# The agent account may not run nextpnr: V2 timing feedback is Gowin's only.
for f in "$TC"/oss-cad-suite/bin/nextpnr-* "$TC"/oss-cad-suite/libexec/nextpnr-*; do
  chown "root:$OP" "$f"; chmod 750 "$f"
done

# 5. Permissions: bin/toolchain/venv read-only for both; clones read-write
#    for both, inherited by everything created inside.
chown -R root:root "$SHARED/bin" "$SHARED/venv"
chmod -R go-w,a+rX "$SHARED/bin" "$SHARED/venv"
# Clone base: agents may traverse, not list; the runner grants each clone
# to the one account running it (tools/bench/runner.py).
chown "$OP:$OP" "$SHARED/clones"
chmod 711 "$SHARED/clones"
setfacl -b "$SHARED/clones"
# Per-run HOMEs: any agent account creates its own, none can list them.
mkdir -p "$SHARED/homes"
chmod 1733 "$SHARED/homes"

# 6. The operator may run processes as the agent accounts (not root), no password.
echo "$OP ALL=($(echo $POOL | tr ' ' ',')) NOPASSWD: ALL" > /etc/sudoers.d/hwebench
chmod 440 /etc/sudoers.d/hwebench
visudo -cf /etc/sudoers.d/hwebench

# 6b. Agents see only their own processes (other runs' command lines are a
#     leak); the operator's group sees all.
GID=$(getent group "$OP" | cut -d: -f3)
mount -o remount,hidepid=invisible,gid="$GID" /proc
grep -q hidepid /etc/fstab || echo "proc /proc proc defaults,hidepid=invisible,gid=$GID 0 0" >> /etc/fstab

# 6c. Ubuntu restricts unprivileged user namespaces through AppArmor; Claude
#     Code's Bash sandbox (nested bubblewrap) needs them, and fails every
#     command without this ("apply-seccomp: write /proc/self/setgroups").
echo 'kernel.apparmor_restrict_unprivileged_userns = 0' > /etc/sysctl.d/60-hwe-bench-userns.conf
sysctl -q -p /etc/sysctl.d/60-hwe-bench-userns.conf
if [ -f /etc/apparmor.d/bwrap-userns-restrict ]; then
  mkdir -p /etc/apparmor.d/disable
  ln -sf /etc/apparmor.d/bwrap-userns-restrict /etc/apparmor.d/disable/bwrap-userns-restrict
  apparmor_parser -R /etc/apparmor.d/bwrap-userns-restrict 2>/dev/null || true
fi

# 7. Verify the boundary and the agent environment.
fail=0
REPO=/home/$OP/auto-arch-tournament
for p in "/home/$OP" "$REPO/bench/holdout" "$REPO/bench/LEADERBOARD.md"; do
  if sudo -u "$U" test -r "$p"; then echo "FAIL: $U can read $p"; fail=1; fi
done
for a in $POOL; do
  sudo -u "$OP" sudo -n -u "$a" true || { echo "FAIL: $OP cannot sudo to $a"; fail=1; }
  sudo -u "$a" ls "$SHARED/clones" >/dev/null 2>&1 && { echo "FAIL: $a can list clones"; fail=1; }
  sudo -u "$a" ls "$SHARED/homes" >/dev/null 2>&1 && { echo "FAIL: $a can list homes"; fail=1; }
  sudo -u "$a" test -r "/proc/1/cmdline" && { echo "FAIL: $a sees other users' processes"; fail=1; }
done
# Claude Code's sandbox: bubblewrap inside bubblewrap.
sudo -u "$U" bwrap --bind / / --dev /dev --proc /proc --unshare-user --unshare-pid -- \
  bwrap --ro-bind / / --dev /dev --proc /proc --unshare-user --unshare-pid -- /bin/true \
  || { echo "FAIL: nested bubblewrap"; fail=1; }
AGENT_PATH="$SHARED/bin:$SHARED/venv/bin:$TC/oss-cad-suite/bin:$TC/bin:/usr/bin:/bin"
if ! sudo -u "$U" env -i HOME="/home/$U" PATH="$AGENT_PATH" /bin/sh -c '
    yosys -V && verilator --version && sby --help >/dev/null &&
    bitwuzla --version && riscv32-unknown-elf-gcc --version && make --version &&
    python3 -c "import cocotb_tools.runner, pytest" && codex --version && claude --version &&
    bwrap --ro-bind / / --dev /dev true' > "$SHARED/setup-check.log" 2>&1; then
  echo "FAIL: agent environment incomplete, see $SHARED/setup-check.log"; fail=1
fi
[ "$fail" = 0 ] || exit 1

cat <<EOF
OK. Operator: $OP (repo in $REPO); agents: $U; shared: $SHARED.
Runner PATH for $OP: $SHARED/venv/bin:$TC/oss-cad-suite/bin:$TC/bin:\$PATH

Two logins remain (once):
  1. Codex, as each of $POOL:
       sudo -iu <account> $SHARED/bin/codex login --device-auth
  2. Claude token:   run 'claude setup-token' (any machine), then as $OP:
       echo 'CLAUDE_CODE_OAUTH_TOKEN=<token>' >> ~/.bench-keys.env && chmod 600 ~/.bench-keys.env
EOF
