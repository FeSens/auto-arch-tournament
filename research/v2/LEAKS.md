# HWE Bench V2: information-leak audit

What an optimization agent could read beyond its own run, how each channel
was found, and how it was closed. A leak here means any information the
agent could use that is not (a) its target core, (b) the evaluation
contract, or (c) its own run's history. Status: **closed** (mitigated and
checked), **open**, or **accepted** (with the reason).

Audit trigger (2026-09-28): the campaign monitor
(`research/v2/scripts/monitor_run.py`) on the V2.0 smoke run showed a Codex
agent searching `cores/v1` for past divider work. The harness was frozen as
2.0.0 but no scored run had started; the fixes below ship as 2.1.0.

## Leaks found

| # | Channel | Who could read what | Found by | Mitigation | Status |
|---|---|---|---|---|---|
| 1 | `cores/v1/` in the clone | Every agent: V1's champion RTL and its full hypothesis log (60+ hypotheses with outcomes), tuned to V1's (wrong) timer | Monitor, Codex `rg` into `cores/v1` | Fixture is now an allowlist: `cores/` keeps only `bench` | closed |
| 2 | `README.md` in the clone | Every agent: V1's 10 accepted winners in merge order with Fmax and CoreMark, i.e. an optimization roadmap | Audit of kept files | README is not in the allowlist (the eval never reads it) | closed |
| 3 | Reference cores, `cores/baseline`, `bench/reference-cores.md`, `BENCH_METHODOLOGY.md`, `CITATION.cff`, `.design`, `.github` | Every agent: prior designs and benchmark docs | Audit of kept files | Allowlist | closed |
| 4 | Agent prompts | Prompts told agents `cores/v1` and `cores/baseline` were "read-only reference", inviting the read | Audit | Sentences removed | closed |
| 5 | Other live runs' clones | All runs shared one OS account (`hwebench`); Codex's sandbox reads the whole filesystem, Claude's Bash sandbox did not deny other clones. Checked: as `hwebench`, the Opus run could list the Sol run's RTL | Audit | Pool of accounts (`hwebench`, `hwebench2`, `hwebench3`), one per concurrent run; each clone's ACL admits only its run's account; the clone base is traverse-only (0711); the runner refuses to start with fewer accounts than concurrent runs | closed (pending host step) |
| 6 | Other runs' Claude transcripts | `~hwebench/.claude/projects/` held every Claude session of every run, readable by any later run (Codex could read it directly) | Audit | Fresh HOME per run (`/srv/hwebench/homes/<run>`, 0700, in a 1733 directory nobody can list), deleted when the run ends; the account's real home keeps only its Codex login and is denied to Claude's sandbox | closed (pending host step) |
| 7 | Earlier runs of the same account | Leftovers in `/tmp`, `/var/tmp`, `/dev/shm`, stray processes | Audit | On release the runner kills the account's processes and deletes its files in those directories and its run homes, and removes the account from the finished clone's ACL | closed |
| 8 | Other runs' processes | `ps` showed every agent's command line (paths, file names, prompts of tool calls). Codex agents ran `pgrep -af` during the smoke | Monitor (`lists processes`) | `/proc` mounted `hidepid=invisible`; the operator's group is exempt | closed (pending host step) |
| 9 | World-readable files agents write outside the clone | Agents ran with umask 002, so files in `/tmp` were readable by other accounts | Audit | Agent umask 007 (inside the clone the default ACL still grants the operator) | closed |
| 10 | Codex web search | Codex 0.156's default `web_search` mode is "cached" (OpenAI's index); the benchmark's results are public (hwebench.com, the GitHub repo). No web search appeared in the smoke transcripts | Audit of the CLI's config keys | `web_search = "disabled"` in the per-run Codex config (tested) | closed |
| 11 | Hints in harness source comments | `tools/eval/gowin.py` named V0's single-cycle divider and V1's best Fmax; `tools/worktree.py` mentioned a multi-cycle divider | Grep of kept files for model names, results, design terms | Comments rewritten to be design-neutral | closed |
| 12 | Runner code and model list | `tools/bench/` (runner, `models-v2.yaml`) and `tools/site/` in the clone | Audit | Not in the allowlist (the eval does not import them) | closed |

## Channels checked and already closed in V2.0

| Channel | Mitigation |
|---|---|
| Held-out kernels (`bench/holdout`) | Stripped from the clone and from every reachable git object (single parentless root commit, reflog expired, gc) |
| Published results (`bench/<model>/rep*`, leaderboard, results.jsonl, research, docs, site) | Same strip; the operator's home (`/home/bench`, the results) is unreadable to agent accounts (checked by the runner at start) |
| Operator CLI state (memories, plugins, MCP, skills, hooks) | Isolated `CODEX_HOME` per run with memories off; Claude with `--setting-sources ""`, no MCP, hooks disabled, auto-memory off |
| Network for tools the agent runs | Claude: WebFetch/WebSearch denied, Bash sandbox with no allowed domains; Codex: workspace-write sandbox, network off |
| The eval's own riscv-formal copy | Unwritable and undeletable for the agent; fingerprinted before and after |
| nextpnr (a different timer) | Not executable by agent accounts |
| System logs (sudo logs every agent command line, prompts included) | `/var/log/auth.log` is `syslog:adm 0640` and the journal is `systemd-journal`/`adm`; agent accounts are in neither (checked: `journalctl` as `hwebench` opens no files) |

## Accepted

- The agent can read its own run's history (log of its earlier hypotheses
  and their outcomes). That is the loop's design, identical for all systems.
- The agent can read its own CLI login token (it runs as the account that
  owns it). Not information about the benchmark.
- Gowin, the toolchain and the contract files are public knowledge.

## How the fixes are tested

- `tools/bench/test_runner.py::test_clone_fixture_strips_published_results`:
  V1 material, README, runner code, results and docs are absent from the
  clone and from every git object; the target core and eval inputs remain.
- `tools/bench/test_runner.py::test_agent_pool_gives_each_job_its_own_account`.
- `tools/bench/test_claude_isolation.py::test_env_under_agent_user`: per-run
  HOME, both homes denied to Claude's sandbox, Codex web search disabled.
- `research/v2/scripts/setup_server.sh` step 7: each pool account cannot list
  the clone base or the homes directory, cannot see other users' processes,
  and can run nested bubblewrap.
- Live probe before the campaign (pending): the full smoke (all three systems
  concurrently) with the monitor running, plus a check from each account
  that it cannot read the other runs' clones and homes.

## Paper angle

A benchmark that runs agents concurrently on one host is a shared-machine
security problem, not only a prompt-design one. The V1 leak policy was a
denylist chosen for convenience ("reference cores are read-only
reference"); in V2 it turned out to hand every agent the previous
generation's winning ideas. The rule adopted: the agent sees an allowlist,
each concurrent run is a separate OS principal, and a monitor reads the
transcripts while the runs go.
