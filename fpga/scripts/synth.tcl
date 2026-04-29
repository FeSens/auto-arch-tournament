# Yosys synthesis script: build the Fmax-benchmark wrapper.
#
# $rtl_dir/*.sv is globbed dynamically (core_pkg.sv first for compilation-
# unit-scope typedefs). Hypotheses are allowed to add/rename/delete
# files inside $rtl_dir/, so a hardcoded list would silently break
# restructuring hypotheses (the orchestrator would log them as
# build_failed regardless of merit).
yosys -import

# Path-parametrization. Default preserves the legacy single-rtl/ behavior.
set rtl_dir "rtl"
if {[info exists ::env(RTL_DIR)]} {
    set rtl_dir $::env(RTL_DIR)
}
set gen_dir "generated"
if {[info exists ::env(GEN_DIR)]} {
    set gen_dir $::env(GEN_DIR)
}

# Ordering: read core_pkg.sv first so its typedefs/localparams are
# visible to subsequent files.
read_verilog -sv "$rtl_dir/core_pkg.sv"

# Then everything else under $rtl_dir/. glob -nocomplain handles the empty
# case; we filter core_pkg.sv out to avoid double-include.
foreach f [lsort [glob -nocomplain "$rtl_dir/*.sv"]] {
    if {[file tail $f] == "core_pkg.sv"} { continue }
    read_verilog -sv "$f"
}

read_verilog -sv fpga/core_bench.sv

synth_gowin -top core_bench -json $gen_dir/synth.json

stat
