// rtl/divider.sv
//
// Iterative RV32M divider/remainder unit. Synthesis builds use a restoring
// unsigned divide on absolute operands, with RISC-V signed fixups at the end.
// Fast formal ALTOPS builds return the riscv-formal substitute operation after
// one cycle so the bounded checks stay shallow.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);

`ifdef RISCV_FORMAL_ALTOPS
  logic        done_q;
  logic [31:0] result_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      done_q   <= 1'b0;
      result_q <= 32'b0;
    end else begin
      done_q <= start;
      if (start) begin
        case (op)
          ALU_DIV:  result_q <= (a - b) ^ 32'h7f8529ec;
          ALU_DIVU: result_q <= (a - b) ^ 32'h10e8fd70;
          ALU_REM:  result_q <= (a - b) ^ 32'h8da68fa5;
          ALU_REMU: result_q <= (a - b) ^ 32'h3138d0e1;
          default:  result_q <= 32'b0;
        endcase
      end
    end
  end

  assign busy   = 1'b0;
  assign done   = done_q;
  assign result = result_q;
`else
  logic        running_q;
  logic        done_q;
  logic        rem_result_q;
  logic        negate_quot_q;
  logic        negate_rem_q;
  logic [4:0]  count_q;
  logic [31:0] dividend_abs_q;
  logic [31:0] divisor_abs_q;
  logic [31:0] quotient_q;
  logic [31:0] rem_q;
  logic [31:0] result_q;

  logic        signed_op;
  logic        rem_op;
  logic        div_by_zero;
  logic        signed_overflow;
  logic [31:0] abs_a;
  logic [31:0] abs_b;

  always_comb begin
    signed_op       = (op == ALU_DIV) || (op == ALU_REM);
    rem_op          = (op == ALU_REM) || (op == ALU_REMU);
    div_by_zero     = (b == 32'b0);
    signed_overflow = signed_op && (a == 32'h80000000) && (b == 32'hFFFFFFFF);
    abs_a           = (signed_op && a[31]) ? (~a + 32'd1) : a;
    abs_b           = (signed_op && b[31]) ? (~b + 32'd1) : b;
  end

  logic [32:0] rem_shift;
  logic [32:0] divisor_ext;
  logic [31:0] rem_step;
  logic [31:0] quotient_step;
  logic [31:0] quotient_final;
  logic [31:0] remainder_final;
  logic [31:0] result_final;

  always_comb begin
    rem_shift     = {rem_q, dividend_abs_q[count_q]};
    divisor_ext   = {1'b0, divisor_abs_q};
    rem_step      = rem_shift[31:0];
    quotient_step = quotient_q;

    if (rem_shift >= divisor_ext) begin
      rem_step              = rem_shift[31:0] - divisor_abs_q;
      quotient_step[count_q] = 1'b1;
    end

    quotient_final  = negate_quot_q ? (~quotient_step + 32'd1)
                                    : quotient_step;
    remainder_final = negate_rem_q  ? (~rem_step + 32'd1)
                                    : rem_step;
    result_final    = rem_result_q ? remainder_final : quotient_final;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      running_q      <= 1'b0;
      done_q         <= 1'b0;
      rem_result_q   <= 1'b0;
      negate_quot_q  <= 1'b0;
      negate_rem_q   <= 1'b0;
      count_q        <= 5'b0;
      dividend_abs_q <= 32'b0;
      divisor_abs_q  <= 32'b0;
      quotient_q     <= 32'b0;
      rem_q          <= 32'b0;
      result_q       <= 32'b0;
    end else begin
      done_q <= 1'b0;

      if (running_q) begin
        quotient_q <= quotient_step;
        rem_q      <= rem_step;

        if (count_q == 5'd0) begin
          running_q <= 1'b0;
          result_q  <= result_final;
          done_q    <= 1'b1;
        end else begin
          count_q <= count_q - 5'd1;
        end
      end else if (start) begin
        if (div_by_zero) begin
          result_q <= rem_op ? a : 32'hFFFFFFFF;
          done_q   <= 1'b1;
        end else if (signed_overflow) begin
          result_q <= rem_op ? 32'b0 : 32'h80000000;
          done_q   <= 1'b1;
        end else begin
          running_q      <= 1'b1;
          rem_result_q   <= rem_op;
          negate_quot_q  <= signed_op && (a[31] ^ b[31]);
          negate_rem_q   <= signed_op && a[31];
          count_q        <= 5'd31;
          dividend_abs_q <= abs_a;
          divisor_abs_q  <= abs_b;
          quotient_q     <= 32'b0;
          rem_q          <= 32'b0;
        end
      end
    end
  end

  assign busy   = running_q;
  assign done   = done_q;
  assign result = result_q;
`endif

endmodule
