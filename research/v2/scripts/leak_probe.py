"""Live cross-account leak probe for the V2.1 agent pool: sets up two runs' state
as the runner does, then has each account try to reach the other's clone, run
home, login home, /tmp files, processes and the operator home. Every line but
the own-clone control must say ok. Run as the operator on the run host:
  python3 research/v2/scripts/leak_probe.py"""
import os, subprocess, sys
from pathlib import Path
sys.path.insert(0, ".")
os.environ["HWE_AGENT_USER"] = "hwebench,hwebench2,hwebench3"
from tools.bench import runner as r
base = r.AGENT_SHARED / "clones"
r.lock_clone_base(base)
pool = {a.name: a for a in r.agent_pool()}
A, B = pool["hwebench"], pool["hwebench2"]
ca, cb = base / "probe-A", base / "probe-B"
for c, a in ((ca, A), (cb, B)):
    r.rmtree_shared(c); c.mkdir(parents=True); (c / "secret.sv").write_text("module secret; endmodule\n")
    r.share_with_agent(c, a)
    h = r.run_home(a, c.name)
    r.as_agent(a.name, "/bin/mkdir", "-p", "-m", "700", str(h), check=True)
    r.as_agent(a.name, "/bin/sh", "-c", f"umask 007; echo transcript > {h}/t.jsonl; echo tmp > /tmp/probe-{a.name}; sleep 300 &")
def try_(who, desc, *cmd):
    p = r.as_agent(who.name, *cmd, capture_output=True, text=True)
    print(f"{'LEAK' if p.returncode == 0 else 'ok  '}  {who.name}: {desc}")
for x, y, cy in ((A, B, cb), (B, A, ca)):
    try_(x, f"reads {y.name}'s clone", "/bin/cat", str(cy / "secret.sv"))
    try_(x, "lists clone base", "/bin/ls", str(base))
    try_(x, "lists homes", "/bin/ls", str(r.AGENT_SHARED / "homes"))
    try_(x, f"reads {y.name}'s run home", "/bin/cat", str(r.run_home(y, cy.name) / "t.jsonl"))
    try_(x, f"reads {y.name}'s login home", "/bin/ls", str(y.home))
    try_(x, f"reads {y.name}'s /tmp file", "/bin/cat", f"/tmp/probe-{y.name}")
    try_(x, f"sees {y.name}'s processes", "/bin/sh", "-c", f"pgrep -u {y.name} | grep -q .")
    try_(x, "reads operator home", "/bin/ls", "/home/bench")
    try_(x, "reads own clone (should say LEAK)", "/bin/cat", str((ca if x is A else cb) / "secret.sv"))
# release A: its clone, run home, tmp and processes go away for it
r.release_agent(A, ca) if r._FREE_AGENTS else None
r._FREE_AGENTS = None; r.acquire_agent(); r._JOB.agent = None
r.release_agent(A, ca)
try_(A, "reads its finished clone after release", "/bin/cat", str(ca / "secret.sv"))
print(("LEAK" if subprocess.run(["pgrep","-u","hwebench"],capture_output=True).returncode==0 else "ok  ")+"  hwebench: processes left after release (operator view)")
try_(A, "still has /tmp file after release", "/bin/cat", "/tmp/probe-hwebench")
print("run home exists after release:", r.run_home(A, "probe-A").exists())
print("operator sees all procs:", subprocess.run("pgrep -u hwebench2 | wc -l", shell=True, capture_output=True, text=True).stdout.strip())
r.release_agent(B, cb)
for c in (ca, cb): r.rmtree_shared(c)
