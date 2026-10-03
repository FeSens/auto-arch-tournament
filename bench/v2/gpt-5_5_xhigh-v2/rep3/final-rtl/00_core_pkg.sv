// rtl/00_core_pkg.sv
//
// Compatibility shim for raw shell-glob builds that pass rtl/*.sv without
// forcing core_pkg.sv first. Normal project flows read core_pkg.sv explicitly
// before this file, so the guarded include is skipped.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
