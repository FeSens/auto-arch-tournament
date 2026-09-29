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
| 13 | Clone "other" permission bits (found by the live probe after the first fix) | Clones were created with the default umask (o+rx), so with separate accounts any account could still read any clone: the ACL admits one account, but "other" admitted all | `research/v2/scripts/leak_probe.py` | `chmod -R o-rwx` and a default `o::---` ACL on each clone; clone set to 0700 on release | closed |
| 14 | Run homes surviving release (probe) | The wipe looked for the account's run homes by listing the homes directory, which the account cannot list (by design), so they survived | Live probe | The runner deletes the run home by name at release and before creating it | closed |
| 15 | Codex connected apps and plugins | Codex 0.156 enables `apps` and `plugins` by default and loads the ChatGPT account's connectors into every session: the smoke's Codex agents were offered 201 app tools (90 GitHub, plus Sites, Booking.com and the operator's own apps). Through GitHub an agent could read this benchmark's repository (research notes, V1 results) and the operator's private data. No agent called one (smoke transcripts: only shell commands, file edits and messages) | Monitor output showed `.codex-home/plugins/cache/openai-curated-remote` in a scribe's `rg` listing | Per-run config disables `apps`, `plugins`, `remote_plugin`, `plugin_sharing`, browser and computer use, the in-app browser, `tool_suggest`, `skill_mcp_dependency_install`; checked live: the model lists only shell, clock and subagent tools, and no app or plugin cache is written | closed |
| 16 | Claude Code deferred tools | The Claude session offered `ToolSearch`, which loads deferred tools, some reaching the operator's account or the network (cloud triggers, cron, notifications, messaging). No MCP servers or connectors were loaded (`disableClaudeAiConnectors`, strict empty MCP config), and no agent called `ToolSearch` or `Skill` (smoke transcripts: Bash, Edit, Write, Read only) | Session init event in the transcript | `ToolSearch` and those tools denied by name; core tools and subagents (`Task`) stay, matching Codex's core tools and subagents | closed |
| 17 | Claude login token in every agent's environment (incident 05) | Harnesses 2.0 to 2.5 put `CLAUDE_CODE_OAUTH_TOKEN` on the agent launch command line, so every agent had it, the Codex agents included (Codex passes it to their shell commands). Those commands have no network, so it was not usable there; no transcript, Codex session file, result file or archive contains it | Operator, checking the launch path after incident 05's orphaned processes | 2.6: an agent gets only its own provider's credential, from a file its launch wrapper sources and deletes, never on a command line | closed |
| 18 | Claude agents' shell commands unconfined (incident 06) | From 2.5 rc2 to 2.6.0 the Claude Bash sandbox could not start (the private TMPDIR under the worktree was too long for its Unix sockets) and Claude Code ran the session unconfined: network open; the host PID namespace, where the account sees its own processes, i.e. the sibling slots and their CLIs' command lines with prompts; the account's home, which links the pool's shared Codex login. Audit of all 2,083 shell commands and every tool call in the affected Opus transcripts: no network use, nothing read outside the run's clone and the agent's own CLI home (no `/home`, `.codex` or `/srv/hwebench/auth` path) | Monitor HIGH on a `pkill`, then the operator's namespace check | 2.7: sandbox fails closed; TMPDIR under a short per-run base; each run starts with a sandbox probe through the full launch path and stops unless confined; monitor HIGH on sandbox-failure messages and on agent commands in the host PID namespace | closed |
| 12 | Runner code and model list | `tools/bench/` (runner, `models-v2.yaml`) and `tools/site/` in the clone | Audit | Not in the allowlist (the eval does not import them) | closed |

## Measured use of leak 1 (`cores/v1`), in V1 and V2 smokes

Evidence: `research/v2/scripts/v1_contamination_scan.py` ->
`research/v2/v1_contamination.txt`. It counts tool calls whose command or path
arguments name a file under `cores/v1/` (tool output excluded, so echoed
usage text such as `formal/run_all.sh`'s "Example: RTL_DIR=cores/v1/rtl" does
not count), and compares each final design with the V1 files that differ from V0.

- **V1 (published runs with transcripts, controls and aborted runs excluded):
  14 of 36 runs read `cores/v1`**: its experiment log (V1's hypotheses and
  outcomes), its RTL (e.g. `div_unit.sv`), and in 5 runs `cores/v1/LESSONS.md`.
  By system: gpt-5_4_xhigh 3/3 (all three read LESSONS.md), kimi-k2_6 3/3,
  gpt-5_6-sol 2/3 (both read LESSONS.md), gpt-5_4-mini 2/3 (log only),
  gpt-5_6-luna 1/3, gpt-6-astra_max 1/3 (log only), gemini-3_5-flash 1/1,
  gpt-6-sol_xhigh 1/1; never: gpt-5_5 (high, medium, xhigh; 0/9),
  gpt-5_6-terra 0/3, gemini-3_1-pro 0/3, claude-opus-5_5_xhigh 0/1.
- **No verbatim or near-verbatim copy** of a V1-specific file in any V1 final
  design (the one quick-ratio flag, Opus rep1 `core.sv`, is 0.23 similar to
  V1's and 0.42 to V0's: not a copy).
- Within systems that read in some runs and not others, reading runs are not
  consistently higher or lower (n <= 3 per system; correlational only; the
  effect of the reads on V1 scores is **not identified**).
- The prompts invited the reads ("cores/baseline/, cores/v1/ ... are READ-ONLY
  REFERENCE"), so this is harness design, not agent misconduct; but it makes
  V1's per-system results depend on a system's propensity to consult a prior
  solution, which differs sharply between systems (0/9 vs 3/3).
- V2 smokes: V2.0-dev, the Opus agent read V1's `div_unit.sv`, `ex_stage.sv`,
  `alu.sv`, `core.sv`, experiment log and `LESSONS.md` before building its own
  divider; V2.0 smoke2, a GPT-6 Sol agent ran `rg ... 'iterative|restoring
  divider|divider' cores/baseline cores/v1 ...` and got V1 log lines (clone
  deleted; the monitor alert is the record). V2.1 smokes: 0 reads (the
  directory is gone; only echoed usage text mentions it).

## Channels checked and already closed in V2.0

| Channel | Mitigation |
|---|---|
| Held-out kernels (`bench/holdout`) | Stripped from the clone and from every reachable git object (single parentless root commit, reflog expired, gc) |
| Published results (`bench/<model>/rep*`, leaderboard, results.jsonl, research, docs, site) | Same strip; the operator's home (`/home/bench`, the results) is unreadable to agent accounts (checked by the runner at start) |
| Operator CLI state (memories, plugins, MCP, skills, hooks) | Isolated `CODEX_HOME` per run with memories off; Claude with `--setting-sources ""`, no MCP, hooks disabled, auto-memory off |
| Network for tools the agent runs | Claude: WebFetch/WebSearch denied, Bash sandbox with no allowed domains (off from 2.5 rc2 to 2.6.0, leak 18; fails closed and probed per run from 2.7); Codex: workspace-write sandbox, network off |
| The eval's own riscv-formal copy | Unwritable and undeletable for the agent; fingerprinted before and after |
| nextpnr (a different timer) | Not executable by agent accounts |
| Sibling slots of the same run (their worktrees and branches) | Not a leak by the definition above (the run's own work, one system), and a write there could only cost that system its own slot. Claude's Bash sandbox may write anywhere in the run's clone, Codex's only in its worktree. Audit (2.8.0 campaign, 13:50Z): 23,317 tool calls in every archived transcript from incident 03 on, no implementation or hypothesis agent named a sibling's worktree or branch (scribes read the finished round's results by design); the monitor raises HIGH on any such reference. Harness bug found the same day: a slot whose design fails placement keeps its worktree and branch until the run ends (since V1; broken and rejected slots remove theirs), so that design stays readable by later rounds' agents of the same run. 2.8.0 campaign: Luna r11s1 and Opus r13s2; fixed on `v2.9-dev` (2addee8, with a test that fails on 2.8.0); 2.8.0 is kept for all 18 runs so every run has the same harness |
| System logs (sudo logs every agent command line, prompts included) | `/var/log/auth.log` is `syslog:adm 0640` and the journal is `systemd-journal`/`adm`; agent accounts are in neither (checked: `journalctl` as `hwebench` opens no files) |

## Accepted

- The agent can read its own run's history (log of its earlier hypotheses
  and their outcomes). That is the loop's design, identical for all systems.
- The pool shares one Codex login (a group-readable file linked from each
  account's home; per-account copies would be revoked by token rotation).
  Any agent account can read that token; it carries no benchmark
  information. Claude's sandbox is denied the directory (it was not while
  the sandbox was off, 2.5 rc2 to 2.6.0, leak 18; no agent touched it).
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
- `research/v2/scripts/leak_probe.py` (live, on the run host): each account
  tries the other's clone, run home, login home, /tmp files, processes and
  the operator home, and the released account tries its finished clone. The
  first pass found leaks 13 and 14; after the fix every check is closed.
- Pending: the full smoke (all three systems concurrently) with the monitor.

## Paper angle

A benchmark that runs agents concurrently on one host is a shared-machine
security problem, not only a prompt-design one. The V1 leak policy was a
denylist chosen for convenience ("reference cores are read-only
reference"); in V2 it turned out to hand every agent the previous
generation's winning ideas. The rule adopted: the agent sees an allowlist,
each concurrent run is a separate OS principal, and a monitor reads the
transcripts while the runs go.
