// Shared RV32M divider. A request captures the operands and operation;
// completion remains stable until consume. Reset cancels any request.
// Real arithmetic takes magnitude preparation, 32 restoring steps, and
// sign correction, each separated by registers.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        request,
  input  logic        consume,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);
  localparam logic [2:0] IDLE = 3'd0, PREP = 3'd1, COMPLETE = 3'd4;
  logic [2:0] state_q;
  logic [4:0] op_q;
  logic [31:0] a_q, b_q;

`ifndef RISCV_FORMAL_ALTOPS
  localparam logic [2:0] ITER = 3'd2, SIGN = 3'd3;
  logic [31:0] quotient_q, remainder_q, divisor_q;
  logic [4:0] step_q;
  logic quotient_negative_q, remainder_negative_q, zero_q, rem_q;
  logic signed_op;
  logic [32:0] shifted, trial;
  logic [31:0] magnitude_result;
  logic negative_result;

  assign signed_op = (op_q == ALU_DIV || op_q == ALU_REM);
  assign shifted = {remainder_q, quotient_q[31]};
  // The partial dividend has at most 32 bits in all 32 iterations.
  // The subtraction's high bit is the borrow; no comparator is needed.
  assign trial = shifted - {1'b0, divisor_q};
  assign magnitude_result = rem_q ? remainder_q : quotient_q;
  assign negative_result = rem_q ? remainder_negative_q : quotient_negative_q;
`endif

  assign busy = state_q != IDLE;
  assign done = state_q == COMPLETE;

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      op_q <= '0;
      a_q <= '0;
      b_q <= '0;
      result <= '0;
`ifndef RISCV_FORMAL_ALTOPS
      quotient_q <= '0;
      remainder_q <= '0;
      divisor_q <= '0;
      step_q <= '0;
      quotient_negative_q <= 1'b0;
      remainder_negative_q <= 1'b0;
      zero_q <= 1'b0;
      rem_q <= 1'b0;
`endif
    end else begin
      case (state_q)
        IDLE: if (request) begin
          a_q <= a;
          b_q <= b;
          op_q <= op;
          state_q <= PREP;
        end
`ifdef RISCV_FORMAL_ALTOPS
        // Same capture/completion interface, short enough for the fixed
        // formal depth. These are the riscv-formal operation constants.
        PREP: begin
          case (op_q)
            ALU_DIV:  result <= (a_q - b_q) ^ 32'h7f8529ec;
            ALU_DIVU: result <= (a_q - b_q) ^ 32'h10e8fd70;
            ALU_REM:  result <= (a_q - b_q) ^ 32'h8da68fa5;
            ALU_REMU: result <= (a_q - b_q) ^ 32'h3138d0e1;
            default:  result <= '0;
          endcase
          state_q <= COMPLETE;
        end
`else
        PREP: begin
          quotient_q <= (signed_op && a_q[31]) ? (~a_q + 32'd1) : a_q;
          divisor_q <= (signed_op && b_q[31]) ? (~b_q + 32'd1) : b_q;
          remainder_q <= '0;
          quotient_negative_q <= signed_op && (a_q[31] ^ b_q[31]);
          remainder_negative_q <= signed_op && a_q[31];
          zero_q <= b_q == 32'b0;
          rem_q <= (op_q == ALU_REM || op_q == ALU_REMU);
          step_q <= '0;
          state_q <= ITER;
        end
        ITER: begin
          remainder_q <= trial[32] ? shifted[31:0] : trial[31:0];
          quotient_q <= {quotient_q[30:0], !trial[32]};
          step_q <= step_q + 5'd1;
          if (step_q == 5'd31) state_q <= SIGN;
        end
        SIGN: begin
          // INT_MIN/-1 naturally gives quotient INT_MIN, remainder 0.
          // Zero needs an override because the quotient must stay all
          // ones even when the dividend is negative.
          if (zero_q) result <= rem_q ? a_q : 32'hffffffff;
          else result <= negative_result ? (~magnitude_result + 32'd1)
                                         : magnitude_result;
          state_q <= COMPLETE;
        end
`endif
        COMPLETE: if (consume) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
