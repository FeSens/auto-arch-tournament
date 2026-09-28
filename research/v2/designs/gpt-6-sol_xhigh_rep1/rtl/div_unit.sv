// One bit per cycle restoring RV32M divider. done and result remain stable
// until consume, so a stalled EX/MEM boundary cannot lose the answer.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        consume,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);
  localparam logic [1:0] IDLE = 2'd0, RUN = 2'd1, COMPLETE = 2'd2;
  logic [1:0] state_q;

  assign busy = state_q == RUN;
  assign done = state_q == COMPLETE;

`ifdef RISCV_FORMAL_ALTOPS
  // Formal uses the architectural ALTOPS substitutions. Retain a real
  // launch, wait, and completion handshake inside the BMC depth budget.
  logic [31:0] alt_result_q;
  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      alt_result_q <= '0;
    end else begin
      case (state_q)
        IDLE: if (start) begin
          state_q <= RUN;
          case (op)
            ALU_DIV:  alt_result_q <= (a - b) ^ 32'h7f8529ec;
            ALU_DIVU: alt_result_q <= (a - b) ^ 32'h10e8fd70;
            ALU_REM:  alt_result_q <= (a - b) ^ 32'h8da68fa5;
            default:  alt_result_q <= (a - b) ^ 32'h3138d0e1;
          endcase
        end
        RUN: state_q <= COMPLETE;
        COMPLETE: if (consume) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
  assign result = alt_result_q;
`else
  logic [31:0] quotient_q, divisor_q, dividend_q;
  logic [31:0] remainder_q;
  logic [5:0]  steps_q;
  logic        negate_quotient_q, negate_remainder_q;
  logic        rem_op_q, zero_divisor_q;

  logic [32:0] trial;
  logic [31:0] difference;
  logic        subtract;
  always_comb begin
    trial = {remainder_q, quotient_q[31]};
    subtract = trial >= {1'b0, divisor_q};
    difference = trial[31:0] - divisor_q;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      quotient_q <= '0;
      divisor_q <= '0;
      dividend_q <= '0;
      remainder_q <= '0;
      steps_q <= '0;
      negate_quotient_q <= 1'b0;
      negate_remainder_q <= 1'b0;
      rem_op_q <= 1'b0;
      zero_divisor_q <= 1'b0;
    end else begin
      case (state_q)
        IDLE: if (start) begin
          state_q <= RUN;
          quotient_q <= ((op == ALU_DIV || op == ALU_REM) && a[31])
                        ? (~a + 32'd1) : a;
          divisor_q <= ((op == ALU_DIV || op == ALU_REM) && b[31])
                       ? (~b + 32'd1) : b;
          dividend_q <= a;
          remainder_q <= '0;
          steps_q <= 6'd32;
          negate_quotient_q <= (op == ALU_DIV) && (a[31] ^ b[31]);
          negate_remainder_q <= (op == ALU_REM) && a[31];
          rem_op_q <= (op == ALU_REM || op == ALU_REMU);
          zero_divisor_q <= (b == 32'b0);
        end
        RUN: begin
          remainder_q <= subtract ? difference : trial[31:0];
          quotient_q <= {quotient_q[30:0], subtract};
          steps_q <= steps_q - 6'd1;
          if (steps_q == 6'd1) state_q <= COMPLETE;
        end
        COMPLETE: if (consume) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end

  always_comb begin
    if (zero_divisor_q)
      result = rem_op_q ? dividend_q : 32'hffff_ffff;
    else if (rem_op_q)
      result = negate_remainder_q ? (~remainder_q[31:0] + 32'd1)
                                  : remainder_q[31:0];
    else
      result = negate_quotient_q ? (~quotient_q + 32'd1) : quotient_q;
  end
`endif
endmodule
