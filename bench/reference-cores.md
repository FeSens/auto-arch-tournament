# Reference cores — synth-only on Gowin GW2AR-LV18

| Core | Source | Vendored SHA | License | LUTs | Fmax (MHz) | CoreMark/MHz | Citation source | Composite fitness |
|---|---|---|---|---|---|---|---|---|
| PicoRV32 | YosysHQ/picorv32 | `87c89acc18994c8cf9a2311e871818e87d304568` | ISC | (pending) | (pending) | 0.516 | github.com/YosysHQ/picorv32 README | (pending) |
| VexRiscv | SpinalHDL/VexRiscv | `680756065e9e6fc50d8c3d6c58191a16e867d822` | MIT | (pending) | (pending) | 2.30 | github.com/SpinalHDL/VexRiscv README | (pending) |
| Ibex | lowRISC/ibex | `eede2fbbef007d53cafbd85d937b897751c40a54` | Apache-2.0 | (pending) | (pending) | 0.904 (small config) | lowRISC ibex README | (pending) |
| NEORV32 | stnolting/neorv32 | `a0c2020e57bd363675840da1845e7f8bd6d76702` | BSD-3-Clause | (pending) | (pending) | 0.9523 | NEORV32 README | (pending) |

All Fmax and LUT measurements pending local `make synth + make fpga TARGET=<name>` runs by the user (3-seed median). CoreMark/MHz cited from upstream documentation. See `docs/bench-protocol-v1.md` for exact tool versions.

## Notes

- **VexRiscv** is `citation_only: true` — no pre-generated Verilog in the upstream repo. Scala demo sources vendored in `cores/vexriscv/rtl/demo_scala/` for documentation. To enable synthesis, run `sbt "runMain vexriscv.demo.GenFullNoMmuMaxPerf"` locally and place the output `.v` in `cores/vexriscv/rtl/`.
- **NEORV32** sources are VHDL (not Verilog/SystemVerilog). Yosys synthesis requires `ghdl-yosys-plugin`. If not installed, NEORV32 falls back to citation-only.
- **Ibex** multiple CoreMark/MHz figures per upstream README: 0.904 (small/RV32EC), 2.47 (mid/RV32IMC 3-cycle mult), 3.13 (maxperf/RV32IMC 1-cycle mult). `core.yaml` records 0.904 as conservative baseline for the small config.
