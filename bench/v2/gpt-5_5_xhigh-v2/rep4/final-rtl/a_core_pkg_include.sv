// rtl/a_core_pkg_include.sv
//
// Some local lint invocations use a raw shell glob, which may place core.sv
// before core_pkg.sv. This guarded include makes those file-order-fragile
// invocations see the typedefs before any module references them. Normal
// build scripts still pass core_pkg.sv first, making this file a no-op.
`include "core_pkg.sv"
