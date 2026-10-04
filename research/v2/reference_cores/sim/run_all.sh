#!/bin/bash
# Stage 2 for every reference core (sims built with build.sh); reset PCs for
# the cores that do not boot at the ELF entry (0).
cd "$(dirname "$0")"
declare -A RESET=([ibex_small]=80 [ibex_maxperf]=80 [vexriscv_nocache]=80000000 [vexriscv_maxperf]=80000000)
for c in "${@:-picorv32 ueriscv biriscv hazard3 neorv32 ibex_small ibex_maxperf vexriscv_nocache vexriscv_maxperf vexiiriscv}"; do
  for core in $c; do
    nice -n 19 python3 -B run_sim.py $core ${RESET[$core]:+--reset-pc ${RESET[$core]}}
  done
done
