# auto-arch-tournament

An autonomous research loop pointed at a SystemVerilog RV32IM CPU. Each round
the agent proposes a microarchitectural hypothesis, implements it in an
isolated git worktree, then runs it through riscv-formal + Verilator cosim +
3-seed FPGA place-and-route. Only hypotheses that beat the current champion
on CoreMark/MHz get merged.

The repo is multi-core: every architecture lives under `cores/<name>/` with
its own RTL, tests, log, and `core.yaml`. `make loop TARGET=<name>` runs the
loop on one core at a time, on a dedicated `core-<name>` git branch inside
its own worktree, so two cores can iterate in parallel without stomping each
other.

## What came out of it

![CoreMark progress: green dots are accepted winners, orange are rejected, blue/purple bands group tournament rounds.](cores/v1/experiments/progress.png)

73 hypotheses, 9h 51m wall-clock, on the run that produced `cores/v1/` from
`cores/baseline/`. Locked baseline → champion went from
**301 iter/s (2.23 CoreMark/MHz)** to **577 iter/s (2.91 CoreMark/MHz)** —
+92% on fitness, +26% over VexRiscv's published 2.30 CoreMark/MHz, with
40% fewer LUTs.

The 10 accepted winners, in order of merge:

| Δt   | iter/s | CM/MHz | Fmax    | Hypothesis                                    |
|------|--------|--------|---------|-----------------------------------------------|
| 0.0h | 301.04 | 2.226  | 135 MHz | Baseline                                      |
| 0.4h | 313.10 | 2.320  | 135 MHz | Backward-Branch Taken Predictor               |
| 0.7h | 324.48 | 2.348  | 138 MHz | IF Direct-Jump Predictor                      |
| 2.1h | 375.43 | 2.348  | 160 MHz | Cold Multi-Cycle DIV/REM Unit                 |
| 2.7h | 397.55 | 2.366  | 168 MHz | One-Deep Store Retirement Slot                |
| 3.5h | 422.77 | 2.366  | 179 MHz | Segmented RVFI Order Counter                  |
| 3.8h | 472.96 | 2.891  | 164 MHz | Registered Lookahead I-Fetch Replay Predictor |
| 4.0h | 505.65 | 2.891  | 175 MHz | Compressed Resetless I-Fetch Replay Tags      |
| 5.3h | 529.35 | 2.891  | 183 MHz | RTL-Only Hot/Cold ALU Opcode Split            |
| 6.1h | 577.76 | 2.908  | 199 MHz | Banked Registered I-Fetch Replay Predictor    |

Full writeup: [docs/auto-arch-tournament-blog-post.md](docs/auto-arch-tournament-blog-post.md).

## Setup

macOS only for now. One-time toolchain install:

```
bash setup.sh
```

Fetches Verilator, OSS CAD Suite (yosys, nextpnr-himbaechel, sby, bitwuzla),
the riscv-none-elf cross compiler, and a few Python deps into `.toolchain/`.
Tools already on `$PATH` are detected and reused.

You'll also need a coding-agent CLI. Codex is the default; Claude Code works
too — pass `AGENT=claude` to any orchestrator target.

## Run the loop

Every core-touching command takes `TARGET=<name>`. The Makefile errors out
otherwise and lists the cores it found.

```
make next TARGET=v1                        # one round, one slot — smoke test
make loop TARGET=v1 N=10                   # 10 rounds, sequential
make loop TARGET=v1 N=10 K=3               # 10 rounds, 3 parallel slots/round
make loop TARGET=v1 N=10 LUT=3000 COREMARK=400   # set per-target fitness goals
make loop TARGET=v1 N=10 AGENT=claude      # use Claude Code instead of Codex
make loop TARGET=mycore BASE=baseline N=10 # fork a new core from cores/baseline/

make report TARGET=v1                      # summary of cores/v1/experiments/log.jsonl
```

What `make loop TARGET=<name>` does:

1. Creates `.worktrees/<name>/` on branch `core-<name>` if it doesn't exist
   (subsequent runs reuse it). Re-execs make inside the worktree so two
   parallel `make loop`s on different TARGETs don't collide on the git index.
2. For each round:
   - **Hypothesis agent** writes `cores/<name>/experiments/hypotheses/<id>.yaml`
     against the JSON schema. The prompt sees: source RTL, recent log entries,
     `LESSONS.md`, `CORE_PHILOSOPHY.md`, `core.yaml`.
   - **Implementation agent** edits `cores/<name>/rtl/` (and optionally
     `cores/<name>/test/test_*.py`) in a per-slot worktree.
   - **Eval pipeline**: verilator lint → yosys synth → bench `make` → cosim
     build → riscv-formal → Verilator cosim vs. Python ISS → 3-seed FPGA
     P&R + CoreMark. Each step is gated; first failure short-circuits with
     a `broken: <step>: <stderr tail>` outcome.
   - **Scribe** distills one bullet into `cores/<name>/LESSONS.md` so the
     next round's hypothesis agent reads what failed and why.
3. The highest-fitness slot above the current champion merges into
   `core-<name>`. Regressions / broken / placement-failed → worktree
   destroyed, log entry written, next round.

The orchestrator never merges to `main`. Each core's evolution is one PR
diff: `git push -u origin core-<name> && gh pr create --base main`.

To opt out of the worktree wrap (run directly on the current branch):
`make loop TARGET=v1 WORKTREE=`.

Other useful targets — all accept `TARGET=`:

```
make lint TARGET=v1          # verilator lint over cores/v1/rtl/
make test TARGET=v1          # cocotb unit tests under cores/v1/test/
make cosim TARGET=v1         # cosim alone (no orchestrator)
make formal TARGET=v1        # riscv-formal fast suite (ALTOPS — see CLAUDE.md)
make formal-deep TARGET=v1   # full formal suite WITHOUT ALTOPS — slow, real bitvector arithmetic
make fpga TARGET=v1          # FPGA eval alone (3-seed P&R + CoreMark)
make bench                   # build selftest.elf / coremark.elf (shared across cores)
make clean TARGET=v1         # nuke per-core build artifacts
make test-infra              # pytest under tools/ (no TARGET needed)
```

If you SSH-sign your commits and run unattended, `tools/orchestrator.py`
sets `commit.gpgsign=false` for its own subprocess tree so the loop
doesn't hang on a 1Password biometric prompt. Manual commits from your
shell are unaffected.

## Working with multiple cores

The repo holds multiple cores under `cores/<name>/`. Each has its own RTL,
tests, experiment log, `core.yaml`, and `LESSONS.md`. The orchestrator runs
against one core at a time.

**Available cores on `main`:**
- `cores/baseline/` — the original simple RV32IM 5-stage in-order core.
  Universal seed for new cores.
- `cores/v1/` — the evolved core from the historical run shown above
  (branch prediction, banked I-fetch replay, hot/cold ALU split).

Other cores live on their own `core-<name>` branches, not yet merged to
`main` — that's the normal state for a core mid-evolution.

**Forking a new core:**

```
make loop TARGET=mycore BASE=baseline N=20 LUT=3000 COREMARK=400
```

The orchestrator:
1. Copies `cores/baseline/` → `cores/mycore/`.
2. Re-runs the eval gates against the freshly-copied RTL to get a measured
   `current:` block in `cores/mycore/core.yaml` — the first log entry.
3. Iterates `N` rounds, with the LUT/CoreMark targets as Pareto goals.

The work lands on branch `core-mycore` in `.worktrees/mycore/`. To review
or ship:

```
git push -u origin core-mycore
gh pr create --base main
```

This is intentional: each core's evolution is one reviewable diff, and
multiple cores can iterate concurrently — `make loop TARGET=mini` and
`make loop TARGET=maxperf` run side-by-side without colliding because each
runs in its own worktree on its own branch.

**Per-core artifacts** (under `cores/<name>/`):

| File / dir              | Purpose                                                                     |
|-------------------------|-----------------------------------------------------------------------------|
| `rtl/*.sv`              | The design. The agent's playground.                                         |
| `test/test_*.py`        | cocotb tests. The agent may add tests for new modules.                      |
| `core.yaml`             | Declared targets + auto-updated `current:` (running champion's measured numbers). |
| `CORE_PHILOSOPHY.md`    | Optional architect intent — injected verbatim into hypothesis prompts.      |
| `LESSONS.md`            | Append-only one-line lessons from prior iterations (the scribe agent).      |
| `experiments/log.jsonl` | Per-iteration outcomes: proposal + fitness numbers + verdict + lesson.      |
| `experiments/progress.png` | Fitness chart over time.                                                 |

## Philosophy

The orchestrator is hardcoded. The model never edits it. What the model
can touch is small and explicit:

- `cores/<TARGET>/rtl/**` — any SystemVerilog file. Add modules, delete
  modules, rename, restructure, rewrite from scratch. The only top-level
  invariant is the I/O contract on `core.sv` (clock/reset, imem/dmem,
  NRET=2 RVFI).
- `cores/<TARGET>/test/test_*.py` — cocotb suites. Add tests for new modules.

Everything else is off-limits. The path sandbox in `tools/orchestrator.py`
rejects the round *before* any eval runs if the agent touched `formal/`,
`tools/`, `fpga/`, `test/cosim/main.cpp`, the CRC table, or any sibling
core's directory. The agent doesn't get to soften its own grader.

The verifier does the heavy lifting:

- **riscv-formal** — symbolic BMC against RV32IM: decode, traps, ordering,
  liveness, M-ext discipline. ~105 checks at NRET=2.
- **Verilator cosim** — random ~22% bus stalls, RVFI byte-identical against
  a Python ISS on `selftest.elf` and `coremark.elf`.
- **3-seed P&R** — yosys + nextpnr on a Gowin GW2A-LV18 (Tang Nano 20K).
  Median Fmax × CoreMark iter/cycle = fitness. One seed is a coin flip;
  three is comparable across rounds.
- **CoreMark CRC validation** — the four canonical 2K-config CRCs.
  CoreMark prints "Correct operation validated." even when it isn't, so
  the bench re-checks them itself.
- **Path sandbox** — the agent cannot edit anything outside its target
  core's `rtl/` and `test/test_*.py`.

Of 73 hypotheses in the run shown above, 63 were rejected by the verifier.
That's the point.

The full contract — invariants, don't-touch list, what may change — is in
[`CLAUDE.md`](CLAUDE.md). The I/O contract is in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Why this exists

Karpathy's [autoresearch](https://github.com/karpathy/autoresearch) showed
an agent loop finding 20 training-time wins on a nanochat in two days. That
worked because Python and gradient descent are the agent's home turf. This
repo asks whether the recipe generalizes when you point it somewhere it has
no business being good at — SystemVerilog, formal verification, FPGA timing.

It does. But the loop isn't the moat — the loop is commodity. The artifact
that survived 10 wins past 63 rejections wasn't the agent; it was the
verifier. That's the part that encodes what *correct* means in this domain.
The full argument is in the [blog post](docs/auto-arch-tournament-blog-post.md).

## Layout

```
cores/                  # per-target architectures
  <name>/
    rtl/                # SystemVerilog sources (the design — agent-editable)
    test/               # cocotb unit tests (agent-editable)
    experiments/        # log.jsonl + progress.png + transient hypotheses/<id>.yaml
    core.yaml           # declared targets + auto-updated current:
    CORE_PHILOSOPHY.md  # optional architect intent (injected into prompts)
    LESSONS.md          # append-only scribe output

bench/programs/         # selftest.S, crt0.S, link.ld, EEMBC CoreMark — shared, off-limits
formal/                 # riscv-formal wrapper, checks.cfg, run_all.sh — correctness contract
fpga/                   # core_bench.sv, synth.tcl, nextpnr scripts, constraints — fitness contract
test/cosim/             # Verilator cosim harness (main.cpp + reference Python ISS)
tools/                  # orchestrator, worktree manager, eval gates, scribe, plotting
schemas/                # hypothesis + eval-result JSON schemas
docs/                   # design notes, blog post
.worktrees/             # auto-created by `make loop`, one git worktree per TARGET
```

## Tech stack

| Concern        | Tool                                                            |
|----------------|-----------------------------------------------------------------|
| RTL            | SystemVerilog (IEEE 1800-2017 synthesizable subset)             |
| Sim            | Verilator ≥ 5.0                                                 |
| Unit tests     | cocotb ≥ 1.8 (Python harness over Verilator)                    |
| Formal         | YosysHQ riscv-formal (vendored submodule); sby + bitwuzla       |
| Synth          | Yosys + `synth_gowin`                                           |
| Place & route  | nextpnr-himbaechel (Gowin GW2A-LV18QN88C8/I7 = Tang Nano 20K)   |
| Cross-compiler | xPack riscv-none-elf-gcc 15.x (symlinked to riscv32-unknown-elf)|
| Orchestrator   | Python 3.11+, jsonschema, pyyaml, matplotlib                    |
| Coding agent   | Codex CLI (default) or Claude Code (`AGENT=claude`)             |
