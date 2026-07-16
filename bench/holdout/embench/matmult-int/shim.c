/* Held-out harness shim for Embench matmult-int. Calls benchmark_body(1, 1)
   directly each rep (see the HOLDOUT PORT comment in matmult-int.c),
   bypassing benchmark()'s LOCAL_SCALE_FACTOR x GLOBAL_SCALE_FACTOR loop.
   Each call re-copies the reference matrices from *_ref and recomputes
   ResultArray from scratch, so every rep is an independent, deterministic
   20x20 multiply; verify_benchmark() checks ResultArray against the fixed
   expected matrix (its `unused` argument carries no state, so any rep
   count works). */

extern void initialise_benchmark(void);
extern int  benchmark_body(unsigned int lsf, unsigned int gsf);
extern int  verify_benchmark(int unused);

int
holdout_init(void)
{
  initialise_benchmark();
  return 0;
}

void
holdout_body(void)
{
  (void)benchmark_body(1, 1);
}

int
holdout_verify(void)
{
  return verify_benchmark(0);
}
