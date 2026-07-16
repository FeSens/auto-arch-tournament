/* Held-out harness shim for Embench edn. Calls benchmark_body(1, 1)
   directly each rep (see the HOLDOUT PORT comment in libedn.c), bypassing
   benchmark()'s LOCAL_SCALE_FACTOR x GLOBAL_SCALE_FACTOR loop. Each call
   re-initializes its local in_a/in_b vectors from fixed constants and
   reruns the full vec_mpy1/mac/fir/fir_no_red_ld/latsynth/iir1/codebook/
   jpegdct chain into the static a/b/c/d/e/output globals, so every rep is
   deterministic; verify_benchmark() checks those globals (its `unused`
   argument carries no state, so any rep count works). */

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
