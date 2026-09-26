# Ibex — synth-only reference core

Vendored from https://github.com/lowRISC/ibex at commit `eede2fbbef007d53cafbd85d937b897751c40a54`.

License: Apache-2.0 (see `LICENSE`).

Generated configuration: Ibex small/maxperf config (multiple variants vendored; specific variant chosen at synth time).

## Cited CoreMark/MHz

Value: 0.904 (small/RV32EC config); 2.47 (RV32IMC 3-cycle mult); 3.13 (RV32IMC 1-cycle mult with Branch target ALU + Writeback stage)
Source: https://github.com/lowRISC/ibex/blob/eede2fbbef007d53cafbd85d937b897751c40a54/README.md
Compiler context: CoreMark run on Ibex Simple System platform; see `examples/sw/benchmarks/README.md` in upstream for exact flags. Default benchmark build uses standard RISC-V GCC toolchain targeting `rv32imc`.

## Computed reference fitness (synth-only)

Pending local `make synth + make fpga TARGET=ibex` runs by the user. The
composite reference fitness is `Fmax (locally measured) × CoreMark/MHz
(cited)`.

## Notes

lowRISC. OpenTitan-deployed. Configurable (small / maxperf, with/without PMP, single-cycle / multi-cycle multiplier). Yosys+nextpnr-himbaechel may not synthesize all SystemVerilog features used (interfaces, generate, classes); fallback to citation-only is documented in §7 of the paper. Three CoreMark/MHz figures from upstream README depending on config: 0.904 (small), 2.47 (mid), 3.13 (maxperf). The `citation_only` field in `core.yaml` records the small-config figure (0.904) as the conservative baseline.
