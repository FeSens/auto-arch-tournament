// rtl/00_core_pkg.sv
//
// Compatibility shim for lint commands that pass rtl/*.sv in shell-glob
// order. Normal project builds still pass core_pkg.sv first; this file only
// includes it when the guard has not already been defined.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
