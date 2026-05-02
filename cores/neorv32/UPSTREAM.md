# NEORV32 — synth-only reference core

Vendored from https://github.com/stnolting/neorv32 at commit `a0c2020e57bd363675840da1845e7f8bd6d76702`.

License: BSD-3-Clause (see `LICENSE`).

Generated configuration: NEORV32 default RV32IM config (no FPU, no MMU). Multi-file VHDL (not Verilog).

## Cited CoreMark/MHz

Value: 0.9523
Source: https://github.com/stnolting/neorv32/blob/a0c2020e57bd363675840da1845e7f8bd6d76702/README.md (also https://stnolting.github.io/neorv32/#_performance)
Compiler context: `riscv32-unknown-elf-gcc -march=rv32imc_zicsr_zifencei -mabi=ilp32 -O3` (per `sw/example/coremark/makefile` and `sw/common/common.mk` in upstream)

## Computed reference fitness (synth-only)

Pending local `make synth + make fpga TARGET=neorv32` runs by the user. The
composite reference fitness is `Fmax (locally measured) × CoreMark/MHz
(cited)`.

## Notes

Nolting 2020–present. **VHDL.** Yosys requires `ghdl-yosys-plugin` for VHDL synthesis. If that's not installed in the bench's `.toolchain/`, NEORV32 falls back to citation-only. Upstream README cites 0.9523 CoreMarks/MHz for an RTOS-capable `rv32imc_Zicsr_Zicntr` configuration on an Altera Cyclone IV E EP4CE22F17C6 FPGA running at up to 130 MHz. The RTL vendored here is the full `rtl/core/` tree (56 VHDL files).
