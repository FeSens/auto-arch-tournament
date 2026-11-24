// MEM half of RV32M multiplication. Sum the shifted products modulo 2^64.
module mul_reduce (
  input  mul_products_t products,
  output logic [31:0]   result
);

`ifdef RISCV_FORMAL_ALTOPS
  assign result = products.alternate;
`else
  logic [47:0] outer_terms, lo_hi, hi_lo;
  logic [47:0] sum, carry, upper;

  // The bottom 16 bits come solely from lo_lo. In the upper 48 bits,
  // hi_hi and lo_lo occupy disjoint ranges and form one term.
  assign outer_terms = {products.hi_hi, products.lo_lo[31:16]};
  assign lo_hi = {{15{products.lo_hi[32]}}, products.lo_hi};
  assign hi_lo = {{15{products.hi_lo[32]}}, products.hi_lo};

  assign sum   = outer_terms ^ lo_hi ^ hi_lo;
  assign carry = (outer_terms & lo_hi) | ((outer_terms | lo_hi) & hi_lo);
  assign upper = sum + (carry << 1);
  assign result = products.high_half ? upper[47:16] : {upper[15:0], products.lo_lo[15:0]};
`endif

endmodule
