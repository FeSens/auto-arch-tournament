# Yosys synthesis script: build the Fmax-benchmark wrapper.
#
# rtl/*.sv is globbed dynamically (core_pkg.sv first for compilation-
# unit-scope typedefs). Hypotheses are allowed to add/rename/delete
# files inside rtl/, so a hardcoded list would silently break
# restructuring hypotheses (the orchestrator would log them as
# build_failed regardless of merit).
yosys -import

# Ordering: read core_pkg.sv first so its typedefs/localparams are
# visible to subsequent files.
read_verilog -sv rtl/core_pkg.sv

# Then everything else under rtl/. glob -nocomplain handles the empty
# case; we filter core_pkg.sv out to avoid double-include.
foreach f [lsort [glob -nocomplain rtl/*.sv]] {
    if {[file tail $f] == "core_pkg.sv"} { continue }
    read_verilog -sv $f
}

read_verilog -sv fpga/core_bench.sv

synth_gowin -top core_bench -json generated/synth.json

stat
