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
	@echo "  make formal     — riscv-formal full check suite (sby)"
	@echo "  make fpga       — FPGA fitness eval (3-seed nextpnr median Fmax + CoreMark cycles)"
	@echo "  make next       — one orchestrator iteration (hypothesize -> implement -> eval)"
	@echo "  make loop N=10  — N orchestrator iterations"
	@echo "  make report     — print experiment summary"
	@echo "  make bench      — build selftest.elf / coremark.elf"
	@echo "  make clean      — remove build artifacts and worktrees"

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

cosim:
	@echo "TODO (phase 3): python3 -m tools.eval.cosim ."
	@false

formal:
	@echo "TODO (phase 4): bash formal/run_all.sh"
	@false

bench:
	@echo "TODO (phase 5): make -C bench/programs all"
	@false

fpga:
	@echo "TODO (phase 6): python3 -m tools.eval.fpga ."
	@false

next:
	@echo "TODO (phase 7): python3 -m tools.orchestrator --iterations 1"
	@false

loop:
	@echo "TODO (phase 7): python3 -m tools.orchestrator --iterations $(N)"
	@false

report:
	@echo "TODO (phase 7): python3 -m tools.orchestrator --report"
	@false

clean:
	rm -rf test/cosim/obj_dir test/cosim/sim_build sim_build out
	rm -rf experiments/worktrees
	find test -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
	find tools -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
