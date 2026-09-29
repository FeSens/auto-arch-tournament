"""Sandbox probe: before a run starts, its agent CLI runs one harness
command through the exact launch path its agents use (account, scope,
private TMPDIR, sandbox settings), and the run starts only if that command
ran confined: its own PID and mount namespaces, no network, and for Claude
the account's home hidden.

V2 incident 06: Claude Code's Bash sandbox could not start (its socket
paths under a long TMPDIR exceeded the Unix limit) and, by default, ran
every command unconfined without saying so, for two campaigns and three
smokes. Nothing checked that the sandbox was actually there.

Run inside the clone with the job's environment (tools/bench/runner.py
run_sandbox_probe):  python3 -m tools.bench.sandbox_probe <out_dir>
Writes <out_dir>/verdict.json and exits 0 when confined, 1 otherwise."""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

PROBE_SH = """#!/bin/sh
# HWE Bench harness sandbox probe (tools/bench/sandbox_probe.py).
out="$1"; home="$2"
{
  echo "pidns=$(readlink /proc/self/ns/pid)"
  echo "mntns=$(readlink /proc/self/ns/mnt)"
  if curl -s -m 8 -o /dev/null https://example.com; then echo "network=open"; else echo "network=blocked"; fi
  if [ -n "$(ls -A "$home" 2>/dev/null)" ]; then echo "account_home=visible"; else echo "account_home=hidden"; fi
} > "$out" 2>/dev/null
"""

PROMPT = ("This is a harness check before the run starts. Run exactly this one "
          "shell command, then reply with the single word done:\n\n{cmd}\n")


def judge(observed: dict, host: dict, provider: str) -> list[str]:
    """Reasons the observed command was not confined (empty: confined)."""
    if not observed:
        return ["the agent did not run the probe command (no result file)"]
    reasons = []
    for ns in ("pidns", "mntns"):
        if not observed.get(ns):
            reasons.append(f"{ns} not reported")
        elif observed[ns] == host[ns]:
            reasons.append(f"{ns} is the host's ({observed[ns]}): no sandbox")
    if observed.get("network") != "blocked":
        reasons.append(f"network {observed.get('network', 'not reported')}")
    if provider == "claude" and observed.get("account_home") != "hidden":
        reasons.append(f"account home {observed.get('account_home', 'not reported')}")
    return reasons


def main(out_dir: str) -> int:
    from tools.agents import _runtime
    out = Path(out_dir).resolve()
    out.mkdir(parents=True, exist_ok=True)
    script, result = out / "probe.sh", out / "result.txt"
    script.write_text(PROBE_SH)
    result.unlink(missing_ok=True)
    provider = _runtime.get_provider()
    home = os.path.expanduser(f"~{os.environ.get('HWE_AGENT_USER', '').strip()}") \
        if os.environ.get("HWE_AGENT_USER") else os.path.expanduser("~")
    prompt = PROMPT.format(cmd=f"sh {script} {result} {home}")
    cmd = _runtime.build_agent_cmd(prompt, os.getcwd(), output_last_message=out / "last.txt",
                                   provider=provider)
    rc, timed_out = _runtime.run_agent_streaming(cmd, os.getcwd(), out / "agent.log", 600,
                                                 provider=provider)
    observed = {}
    if result.is_file():
        for line in result.read_text().splitlines():
            k, _, v = line.partition("=")
            if k:
                observed[k.strip()] = v.strip()
    host = {"pidns": os.readlink("/proc/self/ns/pid"), "mntns": os.readlink("/proc/self/ns/mnt")}
    reasons = judge(observed, host, provider)
    verdict = {"ok": not reasons, "provider": provider, "reasons": reasons,
               "observed": observed, "host": host, "agent_rc": rc, "timed_out": timed_out}
    (out / "verdict.json").write_text(json.dumps(verdict, indent=1) + "\n")
    print(json.dumps(verdict))
    return 0 if verdict["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
