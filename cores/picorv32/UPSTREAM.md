# PicoRV32 — synth-only reference core

Vendored from https://github.com/YosysHQ/picorv32 at commit `87c89acc18994c8cf9a2311e871818e87d304568`.

License: ISC (see `LICENSE`).

Generated configuration: PicoRV32 default RV32IMC config (no caches, no MMU). Single Verilog file.

## Cited CoreMark/MHz

Value: 0.516
Source: https://github.com/YosysHQ/picorv32/blob/87c89acc18994c8cf9a2311e871818e87d304568/README.md
Compiler context: `riscv32-unknown-elf-gcc -Os -mabi=ilp32 -march=rv32im`

## Computed reference fitness (synth-only)

Pending local `make synth + make fpga TARGET=picorv32` runs by the user. The
composite reference fitness is `Fmax (locally measured) × CoreMark/MHz
(cited)`.

## Notes

Wolf 2015–present. RVFI exposed via `ENABLE_RVFI` parameter; signal-name remapping required for modern riscv-formal.
