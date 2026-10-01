// Keep direct rtl/*.sv lint globs' package declarations ahead of files with
// compilation-unit typedef references. Normal build scripts also pass
// core_pkg.sv first; its include guard prevents a duplicate declaration.
`include "core_pkg.sv"
