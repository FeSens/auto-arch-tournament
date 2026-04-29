// cores/v1/rtl/00_core_pkg_first.sv
//
// The project build scripts pass core_pkg.sv first, but the required manual
// lint command uses a raw cores/v1/rtl/*.sv glob that sorts core.sv before
// core_pkg.sv on this filesystem. Pull core_pkg.sv in early for that command
// only; normal ordered builds hit the guard and this file becomes a no-op.
`ifndef CORE_PKG_DEFINED
`include "cores/v1/rtl/core_pkg.sv"
`endif
