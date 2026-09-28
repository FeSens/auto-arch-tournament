// Keep compilation-unit constants available to plain rtl/*.sv glob builds.
// Normal builds list core_pkg.sv first; its include guard makes this a no-op.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
