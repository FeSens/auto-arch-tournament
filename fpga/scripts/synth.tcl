# Yosys synthesis script: build the deployable Fmax-benchmark wrapper.
#
# Reads core_pkg.sv (compilation-unit scope, must be first) plus every
# rtl/*.sv module, then the fpga wrapper. The wrapper instantiates `core`
# and an LFSR-driven imem so synthesis can't constant-fold pipeline logic.
#
# Output: generated/synth.json — fed to nextpnr-himbaechel.
yosys -import

read_verilog -sv \
  rtl/core_pkg.sv \
  rtl/alu.sv \
  rtl/decoder.sv \
  rtl/imm_gen.sv \
  rtl/reg_file.sv \
  rtl/if_stage.sv \
  rtl/id_stage.sv \
  rtl/ex_stage.sv \
  rtl/mem_stage.sv \
  rtl/wb_stage.sv \
  rtl/hazard_unit.sv \
  rtl/forward_unit.sv \
  rtl/core.sv \
  fpga/core_bench.sv

synth_gowin -top core_bench -json generated/synth.json

stat
