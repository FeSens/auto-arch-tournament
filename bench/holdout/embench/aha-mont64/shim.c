/* Held-out harness shim for Embench aha-mont64. Calls benchmark_body(1, 1)
   directly each rep (see the HOLDOUT PORT comment in mont64.c) instead of
   benchmark()'s LOCAL_SCALE_FACTOR x GLOBAL_SCALE_FACTOR-compounded loop,
   so HOLDOUT_REPS (set in bench/holdout/Makefile) is the only repetition
   knob. initialise_benchmark() seeds the fixed 64-bit operands once;
   benchmark_body returns an error count (0 == correct) each call, and
   verify_benchmark() below just checks the last one, matching Embench's
   own verification convention (each call is independent: same operands
   in, same computation, so any rep's error count is representative). */

extern void initialise_benchmark(void);
extern int  benchmark_body(unsigned int lsf, unsigned int gsf);
extern int  verify_benchmark(int res);

static int last_result;

int
holdout_init(void)
{
  initialise_benchmark();
  return 0;
}

void
holdout_body(void)
{
  last_result = benchmark_body(1, 1);
}

int
holdout_verify(void)
{
  return verify_benchmark(last_result);
}
