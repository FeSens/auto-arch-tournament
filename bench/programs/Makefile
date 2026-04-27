CROSS   := riscv32-unknown-elf
CC      := $(CROSS)-gcc
CFLAGS  := -march=rv32im -mabi=ilp32 -O2 -static -nostartfiles \
           -specs=nano.specs -specs=nosys.specs \
           -T bench/programs/link.ld -Ibench/programs/coremark \
           -Ibench/programs/coremark/baremetal

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
