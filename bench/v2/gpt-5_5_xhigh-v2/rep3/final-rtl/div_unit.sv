// rtl/div_unit.sv
//
// Iterative RV32M divider/remainder unit. One start pulse captures operands,
// then the unit emits a sticky done/result once the operation finishes. The
// caller clears done after accepting the result.
//
// Latency:        1 cycle for architecturally special cases, otherwise
//                 33-ish cycles as seen by EX (32 quotient steps plus
//                 result handoff).
// RVFI fields:    feeds rd_wdata through ex_stage's normal EX/MEM register.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        clear,
  input  logic [4:0]  op,
  input  logic [31:0] dividend,
  input  logic [31:0] divisor,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);

  logic        active_q;
  logic        done_q;
  logic [31:0] result_q;

  logic [31:0] dividend_q;
  logic [31:0] divisor_q;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] quotient_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] remainder_q;
  logic [5:0]  count_q;

  logic result_is_rem_q;
  logic quotient_neg_q;
  logic remainder_neg_q;

  logic signed_op;
  logic result_is_rem;
  logic div_by_zero;
  logic signed_overflow;
  logic dividend_neg;
  logic divisor_neg;

  logic [31:0] abs_dividend;
  logic [31:0] abs_divisor;
  logic [31:0] special_result;

  logic [32:0] divisor_ext;
  logic [32:0] remainder_shift;
  logic [32:0] remainder_sub;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] remainder_next;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] dividend_next;
  logic [31:0] quotient_next;
  logic        quotient_bit;

  logic [31:0] quotient_abs;
  logic [31:0] remainder_abs;
  logic [31:0] quotient_signed;
  logic [31:0] remainder_signed;
  logic [31:0] final_result;

  always_comb begin
    signed_op       = (op == ALU_DIV) || (op == ALU_REM);
    result_is_rem   = (op == ALU_REM) || (op == ALU_REMU);
    div_by_zero     = (divisor == 32'b0);
    signed_overflow = signed_op
                   && (dividend == 32'h80000000)
                   && (divisor  == 32'hFFFFFFFF);
    dividend_neg    = signed_op && dividend[31];
    divisor_neg     = signed_op && divisor[31];

    abs_dividend = dividend_neg ? (~dividend + 32'd1) : dividend;
    abs_divisor  = divisor_neg  ? (~divisor  + 32'd1) : divisor;

    special_result = result_is_rem ? dividend : 32'hFFFFFFFF;
    if (signed_overflow)
      special_result = result_is_rem ? 32'b0 : 32'h80000000;

    divisor_ext      = {1'b0, divisor_q};
    remainder_shift  = {remainder_q, dividend_q[31]};
    quotient_bit     = (remainder_shift >= divisor_ext);
    remainder_sub    = remainder_shift - divisor_ext;
    remainder_next   = quotient_bit ? remainder_sub : remainder_shift;
    dividend_next    = {dividend_q[30:0], 1'b0};
    quotient_next    = {quotient_q[30:0], quotient_bit};

    quotient_abs     = quotient_next;
    remainder_abs    = remainder_next[31:0];
    quotient_signed  = quotient_neg_q  ? (~quotient_abs  + 32'd1) : quotient_abs;
    remainder_signed = remainder_neg_q ? (~remainder_abs + 32'd1) : remainder_abs;
    final_result     = result_is_rem_q ? remainder_signed : quotient_signed;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      active_q        <= 1'b0;
      done_q          <= 1'b0;
      result_q        <= 32'b0;
      dividend_q      <= 32'b0;
      divisor_q       <= 32'b0;
      quotient_q      <= 32'b0;
      remainder_q     <= 32'b0;
      count_q         <= 6'b0;
      result_is_rem_q <= 1'b0;
      quotient_neg_q  <= 1'b0;
      remainder_neg_q <= 1'b0;
    end else if (clear) begin
      done_q <= 1'b0;
    end else if (active_q) begin
      dividend_q  <= dividend_next;
      quotient_q  <= quotient_next;
      remainder_q <= remainder_next[31:0];

      if (count_q == 6'd1) begin
        active_q <= 1'b0;
        done_q   <= 1'b1;
        result_q <= final_result;
        count_q  <= 6'b0;
      end else begin
        count_q <= count_q - 6'd1;
      end
    end else if (start && !done_q) begin
      result_is_rem_q <= result_is_rem;
      quotient_neg_q  <= signed_op && (dividend[31] ^ divisor[31]);
      remainder_neg_q <= signed_op && dividend[31];

      if (div_by_zero || signed_overflow) begin
        result_q <= special_result;
        done_q   <= 1'b1;
      end else begin
        dividend_q  <= abs_dividend;
        divisor_q   <= abs_divisor;
        quotient_q  <= 32'b0;
        remainder_q <= 32'b0;
        count_q     <= 6'd32;
        active_q    <= 1'b1;
        done_q      <= 1'b0;
      end
    end
  end

  assign busy   = active_q;
  assign done   = done_q;
  assign result = result_q;

endmodule
