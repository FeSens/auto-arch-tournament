// Shared RV32M restoring divider. The launch edge performs bits 31:28;
// seven subsequent work edges finish the remaining 28 bits. Completion
// and unsigned results remain registered until accept. All operations,
// including zero divisors and ALTOPS, use exactly this same schedule.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        request,
  input  logic        accept,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        done,
  output logic [31:0] result,
  output logic [31:0] source_a,
  output logic [31:0] source_b
);
  logic [2:0] groups_left;

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result;
  assign result = alt_result;
`else
  logic signed_op, quotient_negative, remainder_negative, select_remainder;
  logic [31:0] magnitude_a, magnitude_b;
  logic [31:0] remainder_q, quotient_q, divisor_q;
  logic [31:0] work_divisor;
  logic [31:0] remainder_step [0:4];
  logic [31:0] quotient_step [0:4];
  logic [32:0] trial [0:3];
  logic [31:0] unsigned_result;
  logic result_negative;

  assign signed_op = (op == ALU_DIV || op == ALU_REM);
  assign magnitude_a = signed_op && a[31] ? -a : a;
  assign magnitude_b = signed_op && b[31] ? -b : b;
  assign remainder_step[0] = busy ? remainder_q : 32'b0;
  assign quotient_step[0] = busy ? quotient_q : magnitude_a;
  assign work_divisor = busy ? divisor_q : magnitude_b;

  // Four explicitly unrolled one-bit restoring steps. Before every
  // shift the partial remainder has at most 31 input bits, so the
  // 33rd subtraction bit is the unsigned borrow, not a signed compare.
  for (genvar i = 0; i < 4; i++) begin : restoring
    assign trial[i] = {1'b0, remainder_step[i][30:0], quotient_step[i][31]}
                    - {1'b0, work_divisor};
    assign remainder_step[i+1] = trial[i][32]
                              ? {remainder_step[i][30:0], quotient_step[i][31]}
                              : trial[i][31:0];
    assign quotient_step[i+1] = {quotient_step[i][30:0], !trial[i][32]};
  end

  assign unsigned_result = select_remainder ? remainder_q : quotient_q;
  assign result_negative = select_remainder ? remainder_negative : quotient_negative;
  assign result = result_negative ? -unsigned_result : unsigned_result;
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      busy <= 1'b0;
      done <= 1'b0;
      groups_left <= 3'b0;
      source_a <= 32'b0;
      source_b <= 32'b0;
`ifdef RISCV_FORMAL_ALTOPS
      alt_result <= 32'b0;
`else
      remainder_q <= 32'b0;
      quotient_q <= 32'b0;
      divisor_q <= 32'b0;
      quotient_negative <= 1'b0;
      remainder_negative <= 1'b0;
      select_remainder <= 1'b0;
`endif
    end else if (!busy && request) begin
      busy <= 1'b1;
      done <= 1'b0;
      groups_left <= 3'd7;
      source_a <= a;
      source_b <= b;
`ifdef RISCV_FORMAL_ALTOPS
      case (op)
        ALU_DIV:  alt_result <= (a - b) ^ 32'h7f8529ec;
        ALU_DIVU: alt_result <= (a - b) ^ 32'h10e8fd70;
        ALU_REM:  alt_result <= (a - b) ^ 32'h8da68fa5;
        ALU_REMU: alt_result <= (a - b) ^ 32'h3138d0e1;
        default:  alt_result <= 32'b0;
      endcase
`else
      remainder_q <= remainder_step[4];
      quotient_q <= quotient_step[4];
      divisor_q <= magnitude_b;
      // A zero divisor naturally produces all quotient bits set and
      // remainder=|a|. Suppress quotient negation for RV32M's -1 result.
      quotient_negative <= signed_op && (a[31] ^ b[31]) && (b != 32'b0);
      remainder_negative <= signed_op && a[31];
      select_remainder <= (op == ALU_REM || op == ALU_REMU);
`endif
    end else if (busy && !done) begin
      groups_left <= groups_left - 3'd1;
      if (groups_left == 3'd1) done <= 1'b1;
`ifndef RISCV_FORMAL_ALTOPS
      remainder_q <= remainder_step[4];
      quotient_q <= quotient_step[4];
`endif
    end else if (done && accept) begin
      busy <= 1'b0;
      done <= 1'b0;
    end
  end
endmodule
