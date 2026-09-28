// Shared RV32M divider: acceptance, four radix-256 work clocks, then
// registered sign/exception correction. The response is valid five clocks
// after acceptance and remains stable until consumed (also in ALTOPS).
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        request,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        response_valid,
  input  logic        consume,
  output logic [31:0] result
);
  typedef enum logic [1:0] {IDLE, WORK, FINISH, RESPONSE} state_t;
  state_t state_q;
  logic [1:0] work_q;

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] a_q, b_q, xor_q;
`else
  logic [31:0] quotient_q, remainder_q, divisor_q, dividend_q;
  logic [31:0] quotient_next, remainder_next;
  logic [32:0] trial;
  logic signed_op, select_rem_q, negate_q, zero_q;
  logic [31:0] magnitude, corrected;

  assign signed_op = (op == ALU_DIV || op == ALU_REM);

  // Each iteration shifts in one dividend bit and emits one quotient
  // bit. Concatenations explicitly widen the trial remainder to 33 bits.
  always_comb begin
    quotient_next = quotient_q;
    remainder_next = remainder_q;
    trial = 33'b0;
    for (int step = 0; step < 8; step++) begin
      trial = {remainder_next, quotient_next[31]};
      quotient_next = {quotient_next[30:0], 1'b0};
      if (trial >= {1'b0, divisor_q}) begin
        trial = trial - {1'b0, divisor_q};
        quotient_next[0] = 1'b1;
      end
      remainder_next = trial[31:0];
    end

    magnitude = select_rem_q ? remainder_q : quotient_q;
    corrected = negate_q ? (32'b0 - magnitude) : magnitude;
    // Magnitude arithmetic naturally handles INT_MIN / -1 and its REM.
    if (zero_q)
      corrected = select_rem_q ? dividend_q : 32'hffffffff;
  end
`endif

  assign busy = (state_q != IDLE);
  assign response_valid = (state_q == RESPONSE);

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      work_q <= 2'b0;
      result <= 32'b0;
`ifdef RISCV_FORMAL_ALTOPS
      a_q <= 32'b0;
      b_q <= 32'b0;
      xor_q <= 32'b0;
`else
      quotient_q <= 32'b0;
      remainder_q <= 32'b0;
      divisor_q <= 32'b0;
      dividend_q <= 32'b0;
      select_rem_q <= 1'b0;
      negate_q <= 1'b0;
      zero_q <= 1'b0;
`endif
    end else begin
      case (state_q)
        IDLE: if (request) begin
          state_q <= WORK;
          work_q <= 2'b0;
`ifdef RISCV_FORMAL_ALTOPS
          // Capture originals, never unsigned magnitudes, for ALTOPS.
          a_q <= a;
          b_q <= b;
          case (op)
            ALU_DIV:  xor_q <= 32'h7f8529ec;
            ALU_DIVU: xor_q <= 32'h10e8fd70;
            ALU_REM:  xor_q <= 32'h8da68fa5;
            ALU_REMU: xor_q <= 32'h3138d0e1;
            default:  xor_q <= 32'b0;
          endcase
`else
          quotient_q <= (signed_op && a[31]) ? (32'b0 - a) : a;
          divisor_q <= (signed_op && b[31]) ? (32'b0 - b) : b;
          remainder_q <= 32'b0;
          dividend_q <= a;
          select_rem_q <= (op == ALU_REM || op == ALU_REMU);
          negate_q <= signed_op && ((op == ALU_REM) ? a[31] : (a[31] ^ b[31]));
          zero_q <= (b == 32'b0);
`endif
        end
        WORK: begin
`ifndef RISCV_FORMAL_ALTOPS
          quotient_q <= quotient_next;
          remainder_q <= remainder_next;
`endif
          work_q <= work_q + 2'd1;
          if (work_q == 2'd3) state_q <= FINISH;
        end
        FINISH: begin
`ifdef RISCV_FORMAL_ALTOPS
          result <= (a_q - b_q) ^ xor_q;
`else
          result <= corrected;
`endif
          state_q <= RESPONSE;
        end
        RESPONSE: if (consume) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
