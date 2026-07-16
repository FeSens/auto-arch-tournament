/* Held-out harness shim for Embench crc32. Calls benchmark_body(1, 1)
   directly each rep (see the HOLDOUT PORT comment in crc_32.c), bypassing
   benchmark()'s LOCAL_SCALE_FACTOR x GLOBAL_SCALE_FACTOR loop; each call
   re-seeds the PRNG (srand_beebs(0)) internally so every rep computes the
   identical CRC deterministically. initialise_benchmark() is a no-op
   upstream (kept for interface symmetry with the other kernels). */

extern void initialise_benchmark(void);
extern int  benchmark_body(unsigned int lsf, unsigned int gsf);
extern int  verify_benchmark(int r);

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
