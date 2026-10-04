`include "core_pkg.sv"
// M arithmetic uses only the registered EX/MEM payload. No younger X or
// divider state participates, even when a new divide has already started.
module m_finish (
  input logic [1:0] kind,
  /* verilator lint_off UNUSEDSIGNAL */
  input mul_partial_t mul_partial,
  input div_token_t div_token,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0] result
);
  logic [31:0] mul_result, div_result;
`ifdef RISCV_FORMAL_ALTOPS
  assign mul_result = mul_partial.alt_result;
  assign div_result = div_token.alt_result;
`else
  logic [63:0] p0, p1, p2, p3, sum1, carry1, sum2, carry2, product;
  // Widen BEFORE shifting, including sign extension of mixed/high limbs.
  assign p0 = {{30{mul_partial.ll[33]}}, mul_partial.ll};
  assign p1 = {{30{mul_partial.lh[33]}}, mul_partial.lh} << 16;
  assign p2 = {{30{mul_partial.hl[33]}}, mul_partial.hl} << 16;
  assign p3 = {{30{mul_partial.hh[33]}}, mul_partial.hh} << 32;
  assign sum1 = p0 ^ p1 ^ p2;
  assign carry1 = ((p0 & p1) | (p0 & p2) | (p1 & p2)) << 1;
  assign sum2 = sum1 ^ carry1 ^ p3;
  assign carry2 = ((sum1 & carry1) | (sum1 & p3) | (carry1 & p3)) << 1;
  assign product = sum2 + carry2;
  assign mul_result = mul_partial.high_word ? product[63:32] : product[31:0];

  logic [31:0] unsigned_div_result;
  // X supplies complete registered values; only selection and sign remain.
  assign unsigned_div_result = div_token.remainder_op ? div_token.remainder
                                                     : div_token.quotient;
  assign div_result = div_token.negate ? -unsigned_div_result : unsigned_div_result;
`endif
  always_comb begin
    case (kind)
      M_MUL: result = mul_result;
      M_DIV: result = div_result;
      default: result = '0;
    endcase
  end
endmodule
