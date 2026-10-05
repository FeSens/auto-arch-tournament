#!/usr/bin/env python3
"""Replay the random-mutation control agent offline (amendment 16 evidence).

Before harness 2.8.4 the agent seeded each slot with
`<RANDOM_AGENT_SEED>:<hypothesis id>`, but the implementation prompt carries
no id, so every slot of a run used `<seed>:no-id`. Nothing is ever accepted,
every slot starts from V0, and so every slot applied the same edit set. This
script reproduces that set for a fixture and seeds: it extracts the fixture
into a scratch git tree, runs the fixture's own `random_agent._implement`
with an id-less prompt (as production did) and prints the agent's mutation
record.

    python3 -B research/v2/scripts/replay_random_agent.py --fixture 6f898db --seeds 101,102,103
        (V1's control: one edit set per rep)
    python3 -B research/v2/scripts/replay_random_agent.py --fixture fad7d02 --seeds 0
        (smoke20 on 2.8.3: the seed was dropped for agent accounts, so 0)

Needs verilator on PATH (the agent redraws until lint passes).
"""
from __future__ import annotations

import argparse
import os
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
PROMPT = ("TARGET CORE: cores/bench/ Edit, create, or delete files in the worktree. "
          "implementation_notes.md")
RUN = ("import sys; sys.path.insert(0, '.')\n"
       "from tools.agents import random_agent as ra\n"
       f"ra._implement({PROMPT!r})\n")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--fixture", required=True)
    ap.add_argument("--seeds", required=True)
    a = ap.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        tree = Path(tmp) / "tree"
        tree.mkdir()
        archive = subprocess.run(["git", "-C", str(REPO), "archive", a.fixture], check=True,
                                 capture_output=True).stdout
        subprocess.run(["tar", "-x", "-C", str(tree)], input=archive, check=True)
        git = ["git", "-C", str(tree), "-c", "user.email=replay@localhost", "-c", "user.name=replay"]
        subprocess.run(git + ["init", "-q"], check=True)
        subprocess.run(git + ["add", "-A"], check=True)
        subprocess.run(git + ["commit", "-q", "-m", a.fixture], check=True)
        ver = subprocess.run(["verilator", "--version"], capture_output=True, text=True).stdout.strip()
        print(f"fixture {a.fixture}; {ver}")
        for seed in a.seeds.split(","):
            env = {**os.environ, "RANDOM_AGENT_SEED": seed}
            subprocess.run(["python3", "-B", "-c", RUN], cwd=tree, env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
            print(f"\n== RANDOM_AGENT_SEED={seed}")
            print((tree / "cores/bench/implementation_notes.md").read_text(), end="")
            subprocess.run(git + ["checkout", "-q", "--", "cores/bench/rtl"], check=True)


if __name__ == "__main__":
    main()
