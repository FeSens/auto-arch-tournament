// rtl/div_unit.sv
//
// Iterative RV32M divider/remainder unit. The EX stage starts this unit for
// DIV/DIVU/REM/REMU and holds the instruction until done is asserted. The
// datapath uses one restoring divide step per cycle; no SystemVerilog / or %
// operators are used in the hardware path.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        accept,
  input  logic [4:0]  op,
  input  logic [31:0] dividend,
  input  logic [31:0] divisor,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);

  logic        busy_q;
  logic        done_q;
  logic [31:0] result_q;

  logic [31:0] dividend_q;
  logic [31:0] divisor_q;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] quotient_q;  // MSB shifts out on the next restoring step.
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] remainder_q;
  logic [5:0]  count_q;

  logic        rem_result_q;
  logic        quotient_neg_q;
  logic        remainder_neg_q;

  logic        signed_op;
  logic        rem_op;
  logic        div_by_zero;
  logic        signed_overflow;
  logic [31:0] dividend_abs;
  logic [31:0] divisor_abs;

  logic [32:0] divisor_ext;
  logic [32:0] remainder_shift;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] remainder_next;  // Bit 32 is provably zero after each step.
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] quotient_next;
  logic [31:0] dividend_shift;

  always_comb begin
    signed_op       = (op == ALU_DIV) || (op == ALU_REM);
    rem_op          = (op == ALU_REM) || (op == ALU_REMU);
    div_by_zero     = (divisor == 32'b0);
    signed_overflow = signed_op
                   && (dividend == 32'h8000_0000)
                   && (divisor  == 32'hffff_ffff);

    dividend_abs = (signed_op && dividend[31]) ? (~dividend + 32'd1)
                                                : dividend;
    divisor_abs  = (signed_op && divisor[31])  ? (~divisor + 32'd1)
                                                : divisor;

    divisor_ext      = {1'b0, divisor_q};
    remainder_shift  = {remainder_q, dividend_q[31]};
    dividend_shift   = {dividend_q[30:0], 1'b0};
    if (remainder_shift >= divisor_ext) begin
      remainder_next = remainder_shift - divisor_ext;
      quotient_next  = {quotient_q[30:0], 1'b1};
    end else begin
      remainder_next = remainder_shift;
      quotient_next  = {quotient_q[30:0], 1'b0};
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      busy_q          <= 1'b0;
      done_q          <= 1'b0;
      result_q        <= 32'b0;
      dividend_q      <= 32'b0;
      divisor_q       <= 32'b0;
      quotient_q      <= 32'b0;
      remainder_q     <= 32'b0;
      count_q         <= 6'b0;
      rem_result_q    <= 1'b0;
      quotient_neg_q  <= 1'b0;
      remainder_neg_q <= 1'b0;
    end else begin
      if (accept && done_q) begin
        done_q <= 1'b0;
      end

      if (start && !busy_q && !done_q) begin
        busy_q          <= 1'b0;
        done_q          <= 1'b1;
        dividend_q      <= 32'b0;
        divisor_q       <= 32'b0;
        quotient_q      <= 32'b0;
        remainder_q     <= 32'b0;
        count_q         <= 6'b0;
        rem_result_q    <= rem_op;
        quotient_neg_q  <= signed_op && (dividend[31] ^ divisor[31]);
        remainder_neg_q <= signed_op && dividend[31];

        if (div_by_zero) begin
          result_q <= rem_op ? dividend : 32'hffff_ffff;
        end else if (signed_overflow) begin
          result_q <= rem_op ? 32'b0 : 32'h8000_0000;
        end else begin
          busy_q      <= 1'b1;
          done_q      <= 1'b0;
          dividend_q  <= dividend_abs;
          divisor_q   <= divisor_abs;
          quotient_q  <= 32'b0;
          remainder_q <= 32'b0;
        end
      end else if (busy_q) begin
        dividend_q  <= dividend_shift;
        quotient_q  <= quotient_next;
        remainder_q <= remainder_next[31:0];

        if (count_q == 6'd31) begin
          busy_q <= 1'b0;
          done_q <= 1'b1;
          if (rem_result_q) begin
            result_q <= remainder_neg_q ? (~remainder_next[31:0] + 32'd1)
                                        : remainder_next[31:0];
          end else begin
            result_q <= quotient_neg_q ? (~quotient_next + 32'd1)
                                       : quotient_next;
          end
        end else begin
          count_q <= count_q + 6'd1;
        end
      end
    end
  end

  assign busy   = busy_q;
  assign done   = done_q;
  assign result = result_q;

endmodule
