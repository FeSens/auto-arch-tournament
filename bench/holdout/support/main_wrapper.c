/* Common driver for every held-out kernel. Each kernel is compiled with
   this file plus a shim.c providing holdout_init/holdout_body/
   holdout_verify (see bench/holdout/Makefile), and with
   -DKERNEL_NAME="<name>" -DHOLDOUT_REPS=<R> on the command line.

   Sequence: init once, bracket HOLDOUT_REPS calls to the kernel body with
   the BENCH_START/BENCH_STOP MMIO markers test/cosim/main.cpp watches for,
   then print exactly one UART line reporting pass/fail. Returning from
   main() hits ebreak via bench/programs/crt0.S. */

#include "holdout_port.h"

#define HOLDOUT_STRINGIFY(x) #x
#define HOLDOUT_TOSTRING(x) HOLDOUT_STRINGIFY(x)
#define REPS_STR HOLDOUT_TOSTRING(HOLDOUT_REPS)

int holdout_init(void);
void holdout_body(void);
int holdout_verify(void);

int
main(void)
{
  unsigned i;  /* declared outside the loop: dhrystone.elf compiles this
                  file under -std=gnu89, which rejects C99 for-loop
                  declarations. */

  if (holdout_init() != 0) {
    ho_puts("HOLDOUT " KERNEL_NAME " reps=0 status=FAIL\n");
    return 1;
  }

  BENCH_START = 1;
  for (i = 0; i < HOLDOUT_REPS; i++)
    holdout_body();
  BENCH_STOP = 1;

  ho_puts(holdout_verify() ? "HOLDOUT " KERNEL_NAME " reps=" REPS_STR " status=PASS\n"
                           : "HOLDOUT " KERNEL_NAME " reps=" REPS_STR " status=FAIL\n");
  return 0;
}
