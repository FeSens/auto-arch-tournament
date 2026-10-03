// Shared blocking RV32M divider. Requests and responses use ready/valid;
// the registered response remains stable until accepted. Normal arithmetic
// takes one preparation cycle, 32 restoring steps, and sign correction.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        req_valid,
  output logic        req_ready,
  input  logic [4:0]  req_op,
  input  logic [31:0] req_a,
  input  logic [31:0] req_b,
  output logic        result_valid,
  input  logic        result_ready,
  output logic [31:0] result
);
  localparam logic [2:0] IDLE = 3'd0, PREP = 3'd1, DONE = 3'd4;
`ifndef RISCV_FORMAL_ALTOPS
  localparam logic [2:0] RUN = 3'd2, SIGN = 3'd3;
`endif
  logic [2:0] state_q;
  logic [31:0] a_q, b_q;
  logic [4:0] op_q;
  logic [31:0] result_q;

  assign req_ready = (state_q == IDLE) && !reset;
  assign result_valid = (state_q == DONE) && !reset;
  assign result = result_q;

`ifndef RISCV_FORMAL_ALTOPS
  logic signed_op, remainder_op;
  logic quotient_negative_q, remainder_negative_q, select_remainder_q;
  logic [31:0] quotient_q, divisor_q;
  // The high remainder bit is always zero after a restoring step.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] remainder_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [5:0] step_q;
  logic [32:0] shifted_remainder, difference;
  logic [31:0] magnitude_result;
  logic negate_result;

  always_comb begin
    signed_op = (op_q == ALU_DIV) || (op_q == ALU_REM);
    remainder_op = (op_q == ALU_REM) || (op_q == ALU_REMU);
    shifted_remainder = {remainder_q[31:0], quotient_q[31]};
    // The borrow bit supplies the comparison, sharing one subtractor.
    difference = shifted_remainder - {1'b0, divisor_q};
    magnitude_result = select_remainder_q ? remainder_q[31:0] : quotient_q;
    negate_result = select_remainder_q ? remainder_negative_q
                                      : quotient_negative_q;
  end
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      a_q <= '0;
      b_q <= '0;
      op_q <= '0;
      result_q <= '0;
`ifndef RISCV_FORMAL_ALTOPS
      quotient_q <= '0;
      divisor_q <= '0;
      remainder_q <= '0;
      step_q <= '0;
      quotient_negative_q <= 1'b0;
      remainder_negative_q <= 1'b0;
      select_remainder_q <= 1'b0;
`endif
    end else begin
      case (state_q)
        IDLE: if (req_valid && req_ready) begin
          a_q <= req_a;
          b_q <= req_b;
          op_q <= req_op;
          state_q <= PREP;
        end
        PREP: begin
`ifdef RISCV_FORMAL_ALTOPS
          // Apply the exact stand-ins to every captured operand pair,
          // including zero divisors and signed overflow.
          case (op_q)
            ALU_DIV:  result_q <= (a_q - b_q) ^ 32'h7f8529ec;
            ALU_DIVU: result_q <= (a_q - b_q) ^ 32'h10e8fd70;
            ALU_REM:  result_q <= (a_q - b_q) ^ 32'h8da68fa5;
            ALU_REMU: result_q <= (a_q - b_q) ^ 32'h3138d0e1;
            default:  result_q <= '0;
          endcase
          state_q <= DONE;
`else
          quotient_q <= (signed_op && a_q[31]) ? -a_q : a_q;
          divisor_q <= (signed_op && b_q[31]) ? -b_q : b_q;
          remainder_q <= '0;
          step_q <= '0;
          quotient_negative_q <= signed_op && (a_q[31] ^ b_q[31]);
          remainder_negative_q <= signed_op && a_q[31];
          select_remainder_q <= remainder_op;
          if (b_q == 32'b0) begin
            result_q <= remainder_op ? a_q : 32'hffffffff;
            state_q <= DONE;
          end else if (signed_op && a_q == 32'h80000000 &&
                       b_q == 32'hffffffff) begin
            result_q <= remainder_op ? 32'b0 : 32'h80000000;
            state_q <= DONE;
          end else begin
            state_q <= RUN;
          end
`endif
        end
`ifndef RISCV_FORMAL_ALTOPS
        RUN: begin
          remainder_q <= difference[32] ? shifted_remainder : difference;
          quotient_q <= {quotient_q[30:0], !difference[32]};
          if (step_q == 6'd31) state_q <= SIGN;
          else step_q <= step_q + 6'd1;
        end
        SIGN: begin
          result_q <= negate_result ? -magnitude_result : magnitude_result;
          state_q <= DONE;
        end
`endif
        DONE: if (result_ready) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
