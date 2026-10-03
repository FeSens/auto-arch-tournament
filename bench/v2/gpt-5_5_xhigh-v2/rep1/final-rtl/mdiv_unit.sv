// rtl/mdiv_unit.sv
//
// Iterative RV32M DIV/DIVU/REM/REMU unit. The EX stage starts this unit only
// for divide/remainder opcodes and stalls the front of the pipeline until
// done is observed. Non-DIV ALU operations stay on the single-cycle ALU path.
//
// Latency:        special cases complete one cycle after start; normal
//                 division completes after 32 restoring-division steps.
// RVFI fields:    feeds rd_wdata for DIV/REM through the EX/MEM register.
module mdiv_unit (
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

  function automatic logic [31:0] neg32(input logic [31:0] value);
    neg32 = ~value + 32'd1;
  endfunction

`ifdef RISCV_FORMAL_ALTOPS
  always_ff @(posedge clock) begin
    if (reset) begin
      busy   <= 1'b0;
      done   <= 1'b0;
      result <= 32'b0;
    end else begin
      busy <= 1'b0;
      done <= 1'b0;
      if (start) begin
        case (op)
          ALU_DIV:  result <= (a - b) ^ 32'h7f8529ec;
          ALU_DIVU: result <= (a - b) ^ 32'h10e8fd70;
          ALU_REM:  result <= (a - b) ^ 32'h8da68fa5;
          ALU_REMU: result <= (a - b) ^ 32'h3138d0e1;
          default:  result <= 32'b0;
        endcase
        done <= 1'b1;
      end
    end
  end
`else
  logic [31:0] dividend_q;
  logic [31:0] divisor_q;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] quotient_q;   // MSB shifts out on the next quotient update.
  logic [32:0] remainder_q;  // Bit 32 is retained in the register for width.
  /* verilator lint_on UNUSEDSIGNAL */
  logic [5:0]  count_q;
  logic        is_rem_q;
  logic        quotient_neg_q;
  logic        remainder_neg_q;

  logic        signed_op;
  logic        rem_op;
  logic        div_by_zero;
  logic        signed_overflow;
  logic [31:0] abs_a;
  logic [31:0] abs_b;
  logic [31:0] special_result;

  logic [32:0] divisor_ext;
  logic [32:0] remainder_shifted;
  logic [32:0] remainder_next;
  logic [31:0] quotient_next;
  logic [31:0] dividend_next;
  logic [31:0] final_quotient;
  logic [31:0] final_remainder;
  logic [31:0] final_result;

  always_comb begin
    signed_op       = (op == ALU_DIV) || (op == ALU_REM);
    rem_op          = (op == ALU_REM) || (op == ALU_REMU);
    div_by_zero     = (b == 32'b0);
    signed_overflow = signed_op && (a == 32'h8000_0000) && (b == 32'hffff_ffff);

    abs_a = (signed_op && a[31]) ? neg32(a) : a;
    abs_b = (signed_op && b[31]) ? neg32(b) : b;

    case (op)
      ALU_DIV,
      ALU_DIVU: special_result = 32'hffff_ffff;
      ALU_REM,
      ALU_REMU: special_result = a;
      default:  special_result = 32'b0;
    endcase
    if (signed_overflow) begin
      special_result = rem_op ? 32'b0 : 32'h8000_0000;
    end

    divisor_ext       = {1'b0, divisor_q};
    remainder_shifted = {remainder_q[31:0], dividend_q[31]};
    dividend_next     = {dividend_q[30:0], 1'b0};

    if (remainder_shifted >= divisor_ext) begin
      remainder_next = remainder_shifted - divisor_ext;
      quotient_next  = {quotient_q[30:0], 1'b1};
    end else begin
      remainder_next = remainder_shifted;
      quotient_next  = {quotient_q[30:0], 1'b0};
    end

    final_quotient  = quotient_neg_q  ? neg32(quotient_next)       : quotient_next;
    final_remainder = remainder_neg_q ? neg32(remainder_next[31:0]) : remainder_next[31:0];
    final_result    = is_rem_q ? final_remainder : final_quotient;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      busy            <= 1'b0;
      done            <= 1'b0;
      result          <= 32'b0;
      dividend_q      <= 32'b0;
      divisor_q       <= 32'b0;
      quotient_q      <= 32'b0;
      remainder_q     <= 33'b0;
      count_q         <= 6'b0;
      is_rem_q        <= 1'b0;
      quotient_neg_q  <= 1'b0;
      remainder_neg_q <= 1'b0;
    end else begin
      done <= 1'b0;

      if (start && !busy) begin
        if (div_by_zero || signed_overflow) begin
          busy   <= 1'b0;
          done   <= 1'b1;
          result <= special_result;
        end else begin
          busy            <= 1'b1;
          dividend_q      <= abs_a;
          divisor_q       <= abs_b;
          quotient_q      <= 32'b0;
          remainder_q     <= 33'b0;
          count_q         <= 6'b0;
          is_rem_q        <= rem_op;
          quotient_neg_q  <= signed_op && (a[31] ^ b[31]);
          remainder_neg_q <= signed_op && a[31];
        end
      end else if (busy) begin
        dividend_q  <= dividend_next;
        quotient_q  <= quotient_next;
        remainder_q <= remainder_next;

        if (count_q == 6'd31) begin
          busy   <= 1'b0;
          done   <= 1'b1;
          result <= final_result;
        end else begin
          count_q <= count_q + 6'd1;
        end
      end
    end
  end
`endif

endmodule
