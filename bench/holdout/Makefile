# bench/holdout/Makefile — five bare-metal held-out benchmark kernels
# (dhrystone, aha-mont64, crc32, matmult-int, edn). Flags mirror
# bench/programs/Makefile exactly (same CROSS, same -march/-mabi/-specs/
# link.ld); see bench/holdout/VENDOR.md for kernel provenance.
#
# `make -f bench/holdout/Makefile all` builds bench/holdout/build/<k>.elf
# for each kernel. HOLDOUT_REPS below is calibrated so each kernel
# brackets to 1M-10M cycles on V0 (cores/baseline) — see
# .superpowers/sdd/e3-task-1-report.md for the calibration run.

CROSS   := riscv32-unknown-elf
CC      := $(CROSS)-gcc

BUILD   := bench/holdout/build
CRT0    := bench/programs/crt0.S
LINK_LD := bench/programs/link.ld

COMMON_CFLAGS := -march=rv32im -mabi=ilp32 -O2 -static -nostartfiles \
                  -specs=nano.specs -specs=nosys.specs -T $(LINK_LD) \
                  -Ibench/holdout/support

SUPPORT_SRCS := bench/holdout/support/holdout_port.c \
                bench/holdout/support/main_wrapper.c \
                bench/holdout/support/sbrk.c

# Per-kernel HOLDOUT_REPS, calibrated on V0 to land bracketed cycles in
# [1M, 10M] (Step 6). See the task report for measured V0 cycles.
DHRYSTONE_REPS    := 6000
MONT64_REPS       := 200
CRC32_REPS        := 90
MATMULT_INT_REPS  := 15
EDN_REPS          := 50

.PHONY: all clean
all: $(BUILD)/dhrystone.elf $(BUILD)/aha-mont64.elf $(BUILD)/crc32.elf \
     $(BUILD)/matmult-int.elf $(BUILD)/edn.elf

$(BUILD):
	mkdir -p $(BUILD)

# --- dhrystone -------------------------------------------------------------
# -std=gnu89: Dhrystone 2.1's C sources use K&R-style function definitions
# (no prototypes) throughout; GCC's default dialect (gnu23) rejects those
# as implicit-int errors. gnu89 accepts the original 1988 source verbatim.
DHRYSTONE_SRCS := bench/holdout/dhrystone/dhry_1.c \
                   bench/holdout/dhrystone/dhry_2.c \
                   bench/holdout/dhrystone/shim.c \
                   $(SUPPORT_SRCS) $(CRT0)

$(BUILD)/dhrystone.elf: $(DHRYSTONE_SRCS) $(LINK_LD) | $(BUILD)
	$(CC) $(COMMON_CFLAGS) -std=gnu89 -Ibench/holdout/dhrystone \
	  -DKERNEL_NAME='"dhrystone"' -DHOLDOUT_REPS=$(DHRYSTONE_REPS) \
	  $(DHRYSTONE_SRCS) -o $@

# --- Embench kernels ---------------------------------------------------
# -DGLOBAL_SCALE_FACTOR=1: each kernel's benchmark()/warm_caches() wrapper
# functions reference this macro even though the holdout shim never calls
# them (it calls the de-staticized benchmark_body() directly instead, see
# the HOLDOUT PORT comment in each kernel's .c file); the value is
# otherwise unused.
EMBENCH_CFLAGS := $(COMMON_CFLAGS) -Ibench/holdout/embench -DGLOBAL_SCALE_FACTOR=1

MONT64_SRCS := bench/holdout/embench/aha-mont64/mont64.c \
               bench/holdout/embench/aha-mont64/shim.c \
               $(SUPPORT_SRCS) $(CRT0)

$(BUILD)/aha-mont64.elf: $(MONT64_SRCS) $(LINK_LD) | $(BUILD)
	$(CC) $(EMBENCH_CFLAGS) -DKERNEL_NAME='"aha-mont64"' \
	  -DHOLDOUT_REPS=$(MONT64_REPS) $(MONT64_SRCS) -o $@

CRC32_SRCS := bench/holdout/embench/crc32/crc_32.c \
              bench/holdout/embench/beebsc.c \
              bench/holdout/embench/crc32/shim.c \
              $(SUPPORT_SRCS) $(CRT0)

$(BUILD)/crc32.elf: $(CRC32_SRCS) $(LINK_LD) | $(BUILD)
	$(CC) $(EMBENCH_CFLAGS) -DKERNEL_NAME='"crc32"' \
	  -DHOLDOUT_REPS=$(CRC32_REPS) $(CRC32_SRCS) -o $@

MATMULT_INT_SRCS := bench/holdout/embench/matmult-int/matmult-int.c \
                     bench/holdout/embench/matmult-int/shim.c \
                     $(SUPPORT_SRCS) $(CRT0)

$(BUILD)/matmult-int.elf: $(MATMULT_INT_SRCS) $(LINK_LD) | $(BUILD)
	$(CC) $(EMBENCH_CFLAGS) -DKERNEL_NAME='"matmult-int"' \
	  -DHOLDOUT_REPS=$(MATMULT_INT_REPS) $(MATMULT_INT_SRCS) -o $@

EDN_SRCS := bench/holdout/embench/edn/libedn.c \
            bench/holdout/embench/edn/shim.c \
            $(SUPPORT_SRCS) $(CRT0)

$(BUILD)/edn.elf: $(EDN_SRCS) $(LINK_LD) | $(BUILD)
	$(CC) $(EMBENCH_CFLAGS) -DKERNEL_NAME='"edn"' \
	  -DHOLDOUT_REPS=$(EDN_REPS) $(EDN_SRCS) -o $@

clean:
	rm -f $(BUILD)/*.elf
