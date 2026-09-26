# Startup environment incident, 2026-09-05

The first attempt at repetition 1 stopped after 32 seconds, during the unchanged baseline formal check. No benchmark model calls occurred (zero hypotheses and zero recorded benchmark tokens). The selected sby used a Python without click. Rechecking with the existing conda Python exposed a second environment mismatch: Homebrew yosys-smtbmc was mixed with the bundled Bitwuzla solver.

The corrected launch places the complete OSS CAD Suite first on PATH, followed by the existing conda Python. The harness, RTL, prompts, and correctness gates are unchanged. The original result, environment, and logs are preserved here; this startup incident is not a scored model repetition.
