# research/v2/xfpga/flow.tcl
#
# Vivado out-of-context flow for the cross-FPGA study (amendment 15, part C).
# Sourced by a per-job job.tcl (written by runner.py) that sets:
#   MODE       synth | impl
#   OUT        job directory (reports and result.tsv go here)
#   PART       xc7a200tsbg484-1
#   TOP        top module (core_bench)
#   synth:     PERIOD, SOURCES (list of {lang lib path}), INCLUDE_DIRS
#   impl:      SYNTH_DCP, DIRECTIVE
#
# synth: read the sources in order, read the clock XDC, synth_design
#        -mode out_of_context with default options, write the checkpoint.
# impl:  open the synthesized checkpoint, opt_design, place_design
#        -directive DIRECTIVE, phys_opt_design, route_design, then the
#        worst setup path of the clock and the utilization reports.
#
# Every result goes to $OUT/result.tsv as key<TAB>value lines; runner.py
# parses it. A failing step writes status <step>_failed and exits 1.

set_param general.maxThreads 2

set res [open [file join $OUT result.tsv] w]
proc kv {k v} {
  global res
  regsub -all {[\t\n]} $v { } v
  puts $res "$k\t$v"
  flush $res
}
proc finish {code} {
  global res
  close $res
  exit $code
}
proc step {name script} {
  set t [clock milliseconds]
  if {[catch {uplevel 1 $script} err]} {
    kv status ${name}_failed
    kv error $err
    kv sec_$name [expr {([clock milliseconds] - $t) / 1000.0}]
    finish 1
  }
  kv sec_$name [expr {([clock milliseconds] - $t) / 1000.0}]
}

kv vivado_version [version -short]
kv mode $MODE
kv part $PART

if {$MODE eq "synth"} {
  kv period [format %.3f $PERIOD]
  set xdc [file join $OUT clock.xdc]
  set f [open $xdc w]
  puts $f "create_clock -period [format %.3f $PERIOD] -name clock \[get_ports clock\]"
  puts $f "set_property HD.CLK_SRC BUFGCTRL_X0Y0 \[get_ports clock\]"
  close $f

  step read {
    foreach src $SOURCES {
      lassign $src lang lib path
      switch -- $lang {
        sv      { read_verilog -sv $path }
        verilog { read_verilog $path }
        vhdl {
          if {$lib ne ""} { read_vhdl -vhdl2008 -library $lib $path } \
          else            { read_vhdl -vhdl2008 $path }
        }
        default { error "unknown language $lang for $path" }
      }
    }
    read_xdc $xdc
  }
  set opts [list -mode out_of_context -top $TOP -part $PART]
  if {[llength $INCLUDE_DIRS] > 0} { lappend opts -include_dirs $INCLUDE_DIRS }
  step synth { synth_design {*}$opts }
  report_utilization -file [file join $OUT synth_util.rpt]
  step write_dcp { write_checkpoint -force [file join $OUT synth.dcp] }
  kv status ok
  finish 0
}

if {$MODE eq "impl"} {
  kv directive $DIRECTIVE
  step open { open_checkpoint $SYNTH_DCP }
  set clk [get_clocks -quiet clock]
  if {[llength $clk] != 1} {
    kv status constraint_failed
    kv error "clock 'clock' missing from the synthesized checkpoint"
    finish 1
  }
  kv period [format %.3f [get_property PERIOD $clk]]
  kv hd_clk_src [get_property HD.CLK_SRC [get_ports clock]]

  step opt      { opt_design }
  step place    { place_design -directive $DIRECTIVE }
  step physopt  { phys_opt_design }
  step route    { route_design }

  # Worst setup path of the clock's own path group (reg-to-reg setup;
  # recovery checks on asynchronous resets are in **async_default** and
  # are reported separately below).
  set p [get_timing_paths -quiet -delay_type max -max_paths 1 -nworst 1 -group [get_path_groups -quiet clock]]
  if {[llength $p] == 0} {
    kv status no_timing_path
    kv error "no setup path in the clock's path group"
  } else {
    kv wns [get_property SLACK $p]
    kv logic_levels [get_property LOGIC_LEVELS $p]
    kv startpoint [get_property STARTPOINT_PIN $p]
    kv endpoint [get_property ENDPOINT_PIN $p]
    kv requirement [get_property REQUIREMENT $p]
    kv datapath_delay [get_property DATAPATH_DELAY $p]
    kv logic_delay [get_property DATAPATH_LOGIC_DELAY $p]
    kv net_delay [get_property DATAPATH_NET_DELAY $p]
    kv skew [get_property SKEW $p]
    kv uncertainty [get_property UNCERTAINTY $p]
  }
  set pa [get_timing_paths -quiet -delay_type max -max_paths 1 -nworst 1]
  if {[llength $pa] > 0} {
    kv wns_all_groups [get_property SLACK $pa]
    kv worst_group_all [get_property GROUP $pa]
  }
  set ph [get_timing_paths -quiet -delay_type min -max_paths 1 -nworst 1]
  if {[llength $ph] > 0} { kv whs [get_property SLACK $ph] }

  report_timing_summary -max_paths 5 -file [file join $OUT timing_summary.rpt]
  report_timing -delay_type max -max_paths 5 -nworst 1 -path_type full \
    -input_pins -file [file join $OUT worst_paths.rpt]
  report_utilization -file [file join $OUT util.rpt]
  report_utilization -hierarchical -hierarchical_depth 2 -file [file join $OUT util_hier.rpt]
  report_route_status -file [file join $OUT route_status.rpt]
  if {[llength $p] > 0} { kv status ok }
  finish 0
}

kv status bad_mode
kv error "unknown MODE $MODE"
finish 1
