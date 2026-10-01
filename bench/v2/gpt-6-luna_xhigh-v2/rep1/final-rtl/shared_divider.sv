// Shared radix-2 restoring divider for RV32 DIV/DIVU/REM/REMU.
// One quotient bit is generated per cycle. Signed operations are reduced
// to unsigned magnitudes and the quotient/remainder signs are restored
// after the final iteration. Division by zero naturally produces an all-1
// quotient and the original dividend as remainder.
module shared_divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        signed_op,
  input  logic        remainder_op,
  input  logic [31:0] dividend,
  input  logic [31:0] divisor,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);

  logic [31:0] quotient_q;
  logic [31:0] divisor_q;
  logic [31:0] remainder_q;
  logic [5:0]  iter_q;
  logic        quotient_neg_q;
  logic        remainder_neg_q;
  logic        remainder_op_q;
  logic        divide_by_zero_q;
  logic [31:0] dividend_q;

  logic        dividend_neg;
  logic        divisor_neg;
  logic [31:0] dividend_mag;
  logic [31:0] divisor_mag;
  logic [32:0] shifted_remainder;
  logic [31:0] quotient_step;
  logic [31:0] remainder_step;

  always_comb begin
    dividend_neg = signed_op && dividend[31];
    divisor_neg  = signed_op && divisor[31];
    dividend_mag = dividend_neg ? (~dividend + 32'd1) : dividend;
    divisor_mag  = divisor_neg  ? (~divisor  + 32'd1) : divisor;

    shifted_remainder = {remainder_q, quotient_q[31]};
    if (shifted_remainder >= {1'b0, divisor_q}) begin
      // The restoring remainder is always below the divisor after this
      // step, so its high bit is zero. Low-word subtraction is sufficient.
      remainder_step = shifted_remainder[31:0] - divisor_q;
      quotient_step = {quotient_q[30:0], 1'b1};
    end else begin
      remainder_step = shifted_remainder[31:0];
      quotient_step = {quotient_q[30:0], 1'b0};
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      quotient_q      <= 32'b0;
      divisor_q       <= 32'b0;
      remainder_q     <= 32'b0;
      iter_q          <= 6'b0;
      quotient_neg_q  <= 1'b0;
      remainder_neg_q <= 1'b0;
      remainder_op_q  <= 1'b0;
      divide_by_zero_q <= 1'b0;
      dividend_q      <= 32'b0;
      busy            <= 1'b0;
      done            <= 1'b0;
      result          <= 32'b0;
    end else begin
      done <= 1'b0;
      if (start && !busy) begin
        quotient_q      <= dividend_mag;
        divisor_q       <= divisor_mag;
        remainder_q     <= 32'b0;
        iter_q          <= 6'b0;
        quotient_neg_q  <= dividend_neg ^ divisor_neg;
        remainder_neg_q <= dividend_neg;
        remainder_op_q  <= remainder_op;
        divide_by_zero_q <= (divisor == 32'b0);
        dividend_q      <= dividend;
        busy            <= 1'b1;
      end else if (busy) begin
        quotient_q  <= quotient_step;
        remainder_q <= remainder_step;
        if (iter_q == 6'd31) begin
          busy   <= 1'b0;
          done   <= 1'b1;
          if (divide_by_zero_q && remainder_op_q)
            result <= dividend_q;
          else if (divide_by_zero_q)
            result <= 32'hFFFFFFFF;
          else if (remainder_op_q)
            result <= remainder_neg_q ? (~remainder_step + 32'd1)
                                      : remainder_step;
          else
            result <= quotient_neg_q ? (~quotient_step + 32'd1)
                                     : quotient_step;
        end else begin
          iter_q <= iter_q + 6'd1;
        end
      end
    end
  end

endmodule
