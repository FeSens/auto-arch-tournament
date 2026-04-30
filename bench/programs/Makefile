CROSS   := riscv32-unknown-elf
CC      := $(CROSS)-gcc

# CoreMark build knobs. Defaults reproduce the V0 baseline (6K data size,
# -O2). Override on the command line for canonical EEMBC reporting:
#     make bench/programs/coremark.elf COREMARK_SIZE=2000 COREMARK_OPT=-O3
# - COREMARK_SIZE: TOTAL_DATA_SIZE in coremark.h (#ifndef-guarded). 2000 is
#   the EEMBC canonical reporting config (used by VexRiscv et al.); 6000
#   makes the matrix/list/state working sets ~3x larger so the score is
#   harder to inflate via register-resident working sets.
# - COREMARK_OPT: gcc optimization. -O3 is the standard CoreMark publication
#   flag; -O2 is what the V0 baseline used.
# Defaults match VexRiscv's published CoreMark methodology so the
# orchestrator's fitness number is directly comparable to public CoreMark
# results. To override (e.g. for the prior 6K -O2 V0 baseline):
#     make bench/programs/coremark.elf COREMARK_SIZE=6000 COREMARK_OPT=-O2
COREMARK_SIZE ?= 2000
COREMARK_OPT  ?= -O3

CFLAGS  := -march=rv32im -mabi=ilp32 $(COREMARK_OPT) -static -nostartfiles \
           -specs=nano.specs -specs=nosys.specs \
           -T bench/programs/link.ld -Ibench/programs/coremark \
           -Ibench/programs/coremark/baremetal \
           -DTOTAL_DATA_SIZE=$(COREMARK_SIZE)

SRCS := bench/programs/coremark/core_list_join.c \
        bench/programs/coremark/core_main.c \
        bench/programs/coremark/core_matrix.c \
        bench/programs/coremark/core_state.c \
        bench/programs/coremark/core_util.c \
        bench/programs/coremark/baremetal/core_portme.c \
        bench/programs/crt0.S

bench/programs/coremark.elf: $(SRCS)
	$(CC) $(CFLAGS) $^ -o $@

bench/programs/selftest.elf: bench/programs/selftest.S
	$(CC) -march=rv32im -mabi=ilp32 -static -nostartfiles \
	  -T bench/programs/link.ld $< -o $@

.PHONY: all clean
all: bench/programs/coremark.elf bench/programs/selftest.elf
clean:
	rm -f bench/programs/*.elf
