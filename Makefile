.PHONY: help lint test cosim formal fpga next loop report bench clean
.DEFAULT_GOAL := help

# Resolve OSS CAD Suite path so commands work even when the user hasn't
# sourced .toolchain/oss-cad-suite/environment in this shell.
TOOLCHAIN_DIR := $(CURDIR)/.toolchain
OSS_BIN       := $(TOOLCHAIN_DIR)/oss-cad-suite/bin
LOCAL_BIN     := $(TOOLCHAIN_DIR)/bin
export PATH := $(OSS_BIN):$(LOCAL_BIN):$(PATH)

help:
	@echo "Targets:"
	@echo "  make lint       — verilator lint over rtl/*.sv"
	@echo "  make test       — cocotb unit tests under pytest"
	@echo "  make cosim      — RVFI cosim against Python ISS"
	@echo "  make formal     — riscv-formal fast suite (with ALTOPS — bypassing only)"
	@echo "  make formal-deep— riscv-formal full suite (no ALTOPS — proves M-ext arithmetic; slow)"
	@echo "  make fpga       — FPGA fitness eval (3-seed nextpnr median Fmax + CoreMark cycles)"
	@echo "  make next       — one orchestrator round (hypothesize -> implement -> eval)"
	@echo "                    flags: K=<slots> AGENT=codex|claude"
	@echo "  make loop N=10  — N orchestrator rounds"
	@echo "                    flags: K=<slots> AGENT=codex|claude"
	@echo "  make report     — print experiment summary"
	@echo "  make bench      — build selftest.elf / coremark.elf"
	@echo "  make clean      — remove build artifacts and worktrees"

# Orchestrator knobs (pass-through to tools.orchestrator):
#   N      — number of rounds for `make loop` (default 10).
#   K      — tournament size, slots per round (default 1 = sequential).
#   AGENT  — codex (default) or claude. Honors a pre-existing
#            AGENT_PROVIDER env var if AGENT isn't set on the make
#            command line.
N     ?= 10
K     ?= 1
AGENT ?= $(or $(AGENT_PROVIDER),codex)

# verilator lint over rtl/. Empty rtl/ is fine — phase 0 acceptance.
# -Wno-MULTITOP: until phase 2's core.sv lands and instantiates everything,
# rtl/ legitimately has multiple top modules. Drop this once phase 2 is in.
lint:
	@if ls rtl/*.sv >/dev/null 2>&1; then \
	  verilator --lint-only -Wall -Wno-MULTITOP -sv rtl/*.sv; \
	else \
	  echo "lint: no source files in rtl/ (phase 0 — expected)"; \
	fi

test:
	pytest -v test/

cosim: cosim-build bench/programs/selftest.elf bench/programs/coremark.elf
	python3 -m tools.eval.cosim .

cosim-build: $(wildcard rtl/*.sv) test/cosim/main.cpp
	bash test/cosim/build.sh

bench/programs/selftest.elf: bench/programs/selftest.S bench/programs/link.ld
	$(MAKE) -f bench/programs/Makefile bench/programs/selftest.elf

formal:
	bash formal/run_all.sh formal/checks.cfg

# formal-deep: same checks WITHOUT RISCV_FORMAL_ALTOPS so bitwuzla
# evaluates the actual MUL/DIV/REM bitvector formulas. SLOW (each
# M-ext check can take 15+ min wall). Use periodically — the
# orchestrator's per-iteration formal gate uses fast `make formal`.
# See formal/checks.cfg comments for the full ALTOPS scope explanation.
formal-deep:
	bash formal/run_all.sh formal/checks-deep.cfg

bench:
	$(MAKE) -f bench/programs/Makefile all

fpga: cosim-build bench/programs/coremark.elf generated/synth.json
	python3 -m tools.eval.fpga .

bench/programs/coremark.elf: bench/programs/Makefile bench/programs/crt0.S \
                              $(wildcard bench/programs/coremark/*.c) \
                              $(wildcard bench/programs/coremark/*.h) \
                              $(wildcard bench/programs/coremark/baremetal/*.c) \
                              $(wildcard bench/programs/coremark/baremetal/*.h)
	$(MAKE) -f bench/programs/Makefile bench/programs/coremark.elf

generated/synth.json: $(wildcard rtl/*.sv) fpga/core_bench.sv fpga/scripts/synth.tcl
	mkdir -p generated
	yosys -c fpga/scripts/synth.tcl

next:
	AGENT_PROVIDER=$(AGENT) python3 -m tools.orchestrator --iterations 1 --tournament-size $(K)

loop:
	AGENT_PROVIDER=$(AGENT) python3 -m tools.orchestrator --iterations $(N) --tournament-size $(K)

report:
	python3 -m tools.orchestrator --report

clean:
	rm -rf test/cosim/obj_dir test/cosim/sim_build sim_build out
	rm -rf experiments/worktrees
	rm -f bench/programs/*.elf
	rm -f test/*.result.xml
	find test -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
	find tools -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
