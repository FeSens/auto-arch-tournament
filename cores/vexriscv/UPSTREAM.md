# VexRiscv — synth-only reference core

Vendored from https://github.com/SpinalHDL/VexRiscv at commit `680756065e9e6fc50d8c3d6c58191a16e867d822`.

License: MIT (see `LICENSE`).

Generated configuration: No pre-generated Verilog found in upstream repo (requires `sbt` to run the SpinalHDL generator). Scala demo sources vendored in `rtl/demo_scala/` for documentation only. This core is marked `citation_only: true` — no RTL synthesis possible without running `sbt`.

## Cited CoreMark/MHz

Value: 2.30
Source: https://github.com/SpinalHDL/VexRiscv/blob/680756065e9e6fc50d8c3d6c58191a16e867d822/README.md
Compiler context: `riscv64-unknown-elf-gcc -O3 -fno-inline` (dhrystone; CoreMark figure from "VexRiscv full no cache" and "VexRiscv full" config rows in upstream README)

## Computed reference fitness (synth-only)

Pending: this core is `citation_only: true` because no pre-generated Verilog exists in the upstream repo. To synthesize VexRiscv, run the SpinalHDL sbt generator locally (`sbt "runMain vexriscv.demo.GenFullNoMmuMaxPerf"`) and drop the output `.v` into `cores/vexriscv/rtl/`, then re-run `make synth + make fpga TARGET=vexriscv`.

## Notes

Papon 2017–present. SpinalHDL → Verilog. RVFI integration via `RvfiPlugin` in the SpinalHDL plugin chain (not enabled in default configs). The upstream repo contains only the SpinalHDL Scala source; pre-generated Verilog for demo configs (GenSmallest, GenFull, GenFullNoMmu, etc.) is not committed to the repository and must be generated locally.
