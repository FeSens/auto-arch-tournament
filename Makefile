.PHONY: help lint test test-infra cosim formal fpga next loop report bench clean
.DEFAULT_GOAL := help

# Resolve OSS CAD Suite path so commands work even when the user hasn't
# sourced .toolchain/oss-cad-suite/environment in this shell.
TOOLCHAIN_DIR := $(CURDIR)/.toolchain
OSS_BIN       := $(TOOLCHAIN_DIR)/oss-cad-suite/bin
LOCAL_BIN     := $(TOOLCHAIN_DIR)/bin
export PATH := $(OSS_BIN):$(LOCAL_BIN):$(PATH)

# Orchestrator knobs (pass-through to tools.orchestrator):
#   N        — number of rounds for `make loop` (default 10).
#   K        — tournament size, slots per round (default 1 = sequential).
#   AGENT    — codex (default) or claude. Honors a pre-existing
#              AGENT_PROVIDER env var if AGENT isn't set on the make
#              command line.
#   BASE     — when forking a new TARGET, copy from cores/<BASE>/.
#              Default: baseline (orchestrator-side default).
#   COREMARK — target CoreMark iterations/sec (e.g. '370').
#   LUT      — target LUT count (e.g. '3000').
#   WORKTREE — when set (any value), `make loop` first creates a dedicated
#              git worktree at .worktrees/<TARGET>/ on branch core-<TARGET>
#              and re-execs itself there. Lets two `make loop` invocations
#              for different TARGETs run in parallel without git collisions.
N        ?= 10
K        ?= 1
AGENT    ?= $(or $(AGENT_PROVIDER),codex)
BASE     ?=
COREMARK ?=
LUT      ?=
WORKTREE ?=

# Compose optional CLI flags for the orchestrator. Empty vars produce
# empty strings so the orchestrator falls back to its defaults.
ORCH_FLAGS  = --iterations $(N) --tournament-size $(K)
ifneq ($(strip $(BASE)),)
  ORCH_FLAGS += --base $(BASE)
endif
ifneq ($(strip $(COREMARK)),)
  ORCH_FLAGS += --coremark-target $(COREMARK)
endif
ifneq ($(strip $(LUT)),)
  ORCH_FLAGS += --lut-target $(LUT)
endif

# Multi-core: TARGET selects the core under cores/<TARGET>/.
# TARGET is required for all core-touching targets (enforced below).
TARGET ?=

# Targets that require TARGET=<core_name>.
CORE_TARGETS := lint test cosim cosim-build formal formal-deep fpga next loop

ifeq ($(strip $(TARGET)),)
  ifneq ($(filter $(MAKECMDGOALS),$(CORE_TARGETS)),)
    $(error TARGET= required. Available cores: $(notdir $(wildcard cores/*)))
  endif
endif

ifneq ($(strip $(TARGET)),)
  RTL_DIR    := cores/$(TARGET)/rtl
  TEST_DIR   := cores/$(TARGET)/test
  CORE_NAME  := $(TARGET)
  OBJ_DIR    := cores/$(TARGET)/obj_dir
  GEN_DIR    := cores/$(TARGET)/generated
  ORCH_TARGET_FLAG := --target $(TARGET)
  # WORKTREE-mode paths (only consumed when WORKTREE= is set on `make loop`).
  WT_BRANCH  := core-$(TARGET)
  WT_PATH    := $(CURDIR)/.worktrees/$(TARGET)
endif

export RTL_DIR CORE_NAME OBJ_DIR GEN_DIR

help:
	@echo "Targets (most accept TARGET=<core_name>):"
	@echo "  make lint TARGET=v1     — verilator lint over cores/<TARGET>/rtl/*.sv"
	@echo "  make test TARGET=v1     — cocotb unit tests under cores/<TARGET>/test/"
	@echo "  make cosim TARGET=v1    — RVFI cosim against Python ISS"
	@echo "  make formal TARGET=v1   — riscv-formal fast suite (with ALTOPS)"
	@echo "  make formal-deep TARGET=v1 — full formal suite without ALTOPS (slow, bitvector-correct)"
	@echo "  make fpga TARGET=v1     — FPGA fitness eval (Fmax + CoreMark cycles)"
	@echo "  make bench              — build selftest + coremark ELFs"
	@echo "  make next TARGET=v1     — one orchestrator round"
	@echo "  make loop TARGET=v1 N=10 [WORKTREE=1] — N orchestrator rounds (WORKTREE=1 spawns .worktrees/<TARGET> on branch core-<TARGET>)"
	@echo "  make report TARGET=v1   — per-core experiment summary"
	@echo "  make clean TARGET=v1    — remove per-core build artifacts (use with TARGET=)"
	@echo "  make test-infra         — run orchestrator infra tests under tools/"
	@echo ""
	@echo "Available cores:"
	@for d in cores/*/; do echo "  - $$(basename $$d)"; done 2>/dev/null || echo "  (none yet)"

# verilator lint over $(RTL_DIR)/.
# -Wno-MULTITOP: until phase 2's core.sv lands and instantiates everything,
# rtl/ legitimately has multiple top modules. Drop this once phase 2 is in.
lint:
	@if ls $(RTL_DIR)/*.sv >/dev/null 2>&1; then \
	  verilator --lint-only -Wall -Wno-MULTITOP -sv +incdir+$(RTL_DIR) $(RTL_DIR)/*.sv; \
	else \
	  echo "lint: no source files in $(RTL_DIR)/"; \
	fi

test:
	pytest -v $(TEST_DIR)/

test-infra:
	pytest -v tools/

cosim: cosim-build bench/programs/selftest.elf bench/programs/coremark.elf
	python3 -m tools.eval.cosim . $(TARGET)

cosim-build: $(wildcard $(RTL_DIR)/*.sv) test/cosim/main.cpp
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

fpga: cosim-build bench/programs/coremark.elf $(GEN_DIR)/synth.json
	python3 -m tools.eval.fpga . $(TARGET)

bench/programs/coremark.elf: bench/programs/Makefile bench/programs/crt0.S \
                              $(wildcard bench/programs/coremark/*.c) \
                              $(wildcard bench/programs/coremark/*.h) \
                              $(wildcard bench/programs/coremark/baremetal/*.c) \
                              $(wildcard bench/programs/coremark/baremetal/*.h)
	$(MAKE) -f bench/programs/Makefile bench/programs/coremark.elf

$(GEN_DIR)/synth.json: $(wildcard $(RTL_DIR)/*.sv) fpga/core_bench.sv fpga/scripts/synth.tcl
	mkdir -p $(GEN_DIR)
	yosys -c fpga/scripts/synth.tcl

next:
	AGENT_PROVIDER=$(AGENT) python3 -m tools.orchestrator $(subst --iterations $(N),--iterations 1,$(ORCH_FLAGS)) $(ORCH_TARGET_FLAG)

loop:
ifneq ($(strip $(WORKTREE)),)
	@if [ ! -d "$(WT_PATH)" ]; then \
	  echo "[wt] creating branch $(WT_BRANCH) and worktree $(WT_PATH)"; \
	  if git rev-parse --verify $(WT_BRANCH) >/dev/null 2>&1; then \
	    git worktree add "$(WT_PATH)" $(WT_BRANCH); \
	  else \
	    git worktree add -b $(WT_BRANCH) "$(WT_PATH)"; \
	  fi; \
	  [ -e "$(WT_PATH)/formal/riscv-formal" ] || ln -s "$(CURDIR)/formal/riscv-formal" "$(WT_PATH)/formal/riscv-formal"; \
	fi
	@$(MAKE) -C "$(WT_PATH)" loop \
	  TARGET=$(TARGET) N=$(N) K=$(K) AGENT=$(AGENT) \
	  $(if $(strip $(BASE)),BASE=$(BASE),) \
	  $(if $(strip $(COREMARK)),COREMARK=$(COREMARK),) \
	  $(if $(strip $(LUT)),LUT=$(LUT),)
else
	AGENT_PROVIDER=$(AGENT) python3 -m tools.orchestrator $(ORCH_FLAGS) $(ORCH_TARGET_FLAG)
endif

report:
	python3 -m tools.orchestrator --report $(ORCH_TARGET_FLAG)

clean:
	rm -rf test/cosim/sim_build sim_build out
	rm -rf experiments/worktrees
	rm -f bench/programs/*.elf
	rm -f test/*.result.xml
	find test -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
	find tools -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
ifneq ($(strip $(TARGET)),)
	rm -rf $(OBJ_DIR)
	rm -rf $(GEN_DIR)
	rm -rf cores/$(TARGET)/sim_build
endif
