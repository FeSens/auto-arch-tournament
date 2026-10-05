// Shared RV32M restoring divider. Requests capture raw operands once;
// normalization, 32 recurrence steps and sign correction are registered.
// Completion stays valid until consumed, independently of memory readiness.
module divider (
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
  typedef enum logic [2:0] {IDLE, NORMALIZE, ITERATE, FINISH, COMPLETE} state_t;
  state_t state_q;
  logic [31:0] a_q, b_q;
  logic [4:0] op_q;

`ifndef RISCV_FORMAL_ALTOPS
  logic [31:0] quotient_q, remainder_q, divisor_q;
  logic [5:0] step_q;
  logic negate_q;
  logic signed_op, remainder_op;
  logic [32:0] shifted_remainder, trial;
  logic [31:0] magnitude;

  assign signed_op = (op_q == ALU_DIV || op_q == ALU_REM);
  assign remainder_op = (op_q == ALU_REM || op_q == ALU_REMU);
  assign shifted_remainder = {remainder_q, quotient_q[31]};
  // The restoring invariant bounds a successful difference to 32 bits;
  // trial[32] therefore indicates borrow. One subtraction per step.
  assign trial = shifted_remainder - {1'b0, divisor_q};
  assign magnitude = remainder_op ? remainder_q : quotient_q;
`endif

  assign busy = (state_q != IDLE);
  assign done = (state_q == COMPLETE);

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      a_q <= 32'b0;
      b_q <= 32'b0;
      op_q <= ALU_DIV;
      result <= 32'b0;
`ifndef RISCV_FORMAL_ALTOPS
      quotient_q <= 32'b0;
      remainder_q <= 32'b0;
      divisor_q <= 32'b0;
      step_q <= 6'b0;
      negate_q <= 1'b0;
`endif
    end else begin
      case (state_q)
        IDLE: if (start) begin
          a_q <= a;
          b_q <= b;
          op_q <= op;
          state_q <= NORMALIZE;
        end
        NORMALIZE: begin
`ifdef RISCV_FORMAL_ALTOPS
          // Exact riscv-formal substitutes, using the captured operands
          // and the same sticky result/consume protocol as real hardware.
          case (op_q)
            ALU_DIV:  result <= (a_q - b_q) ^ 32'h7f8529ec;
            ALU_DIVU: result <= (a_q - b_q) ^ 32'h10e8fd70;
            ALU_REM:  result <= (a_q - b_q) ^ 32'h8da68fa5;
            ALU_REMU: result <= (a_q - b_q) ^ 32'h3138d0e1;
            default:  result <= 32'b0;
          endcase
          state_q <= COMPLETE;
`else
          quotient_q <= (signed_op && a_q[31]) ? -a_q : a_q;
          divisor_q <= (signed_op && b_q[31]) ? -b_q : b_q;
          remainder_q <= 32'b0;
          step_q <= 6'd0;
          negate_q <= signed_op && (remainder_op ? a_q[31] : (a_q[31] ^ b_q[31]));
          if (b_q == 32'b0) begin
            result <= remainder_op ? a_q : 32'hffffffff;
            state_q <= COMPLETE;
          end else begin
            // INT_MIN/-1 naturally produces INT_MIN and zero remainder
            // when represented as unsigned magnitudes.
            state_q <= ITERATE;
          end
`endif
        end
        ITERATE: begin
`ifndef RISCV_FORMAL_ALTOPS
          remainder_q <= trial[32] ? shifted_remainder[31:0] : trial[31:0];
          quotient_q <= {quotient_q[30:0], !trial[32]};
          step_q <= step_q + 6'd1;
          if (step_q == 6'd31) state_q <= FINISH;
`else
          state_q <= IDLE;
`endif
        end
        FINISH: begin
`ifndef RISCV_FORMAL_ALTOPS
          result <= negate_q ? -magnitude : magnitude;
          state_q <= COMPLETE;
`else
          state_q <= IDLE;
`endif
        end
        COMPLETE: if (consume) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
