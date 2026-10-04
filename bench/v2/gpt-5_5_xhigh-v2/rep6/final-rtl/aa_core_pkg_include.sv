// Makes simple wildcard lint commands see core_pkg.sv before alu.sv.
// Normal build scripts already pass core_pkg.sv first; the include guard in
// core_pkg.sv keeps this file a no-op in that case.
`include "core_pkg.sv"
