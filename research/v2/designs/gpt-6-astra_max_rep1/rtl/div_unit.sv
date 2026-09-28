// Fixed eight-edge RV32M divider. The accepting edge computes bits 31:28;
// seven more groups of four restoring steps finish the operation. Result
// correction is captured with the last group, including all special cases.
// A completed result occupies the engine until the ready/valid handshake.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        req_valid,
  output logic        req_ready,
  output logic        result_valid,
  input  logic        result_ready,
  output logic [31:0] result
);
  logic busy_q;
  logic [2:0] group_q;
  logic accept;
  logic legal_op;

  assign legal_op = op == ALU_DIV || op == ALU_DIVU
                 || op == ALU_REM || op == ALU_REMU;
  assign req_ready = !reset && !busy_q && !result_valid;
  assign accept = req_valid && req_ready && legal_op;

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result_q;
  logic [31:0] alt_result;
  always_comb begin
    case (op)
      ALU_DIV:  alt_result = (a - b) ^ 32'h7f8529ec;
      ALU_DIVU: alt_result = (a - b) ^ 32'h10e8fd70;
      ALU_REM:  alt_result = (a - b) ^ 32'h8da68fa5;
      ALU_REMU: alt_result = (a - b) ^ 32'h3138d0e1;
      default:  alt_result = 32'b0;
    endcase
  end
`else
  logic [31:0] divisor_q, quotient_q, remainder_q;
  logic [31:0] dividend_q;
  logic rem_op_q, negate_q, zero_divisor_q;
  logic signed_op, rem_op;
  logic [31:0] magnitude_a, magnitude_b;
  logic [31:0] step_divisor;
  logic [31:0] quotient_step [0:4];
  logic [31:0] remainder_step [0:4];
  logic [32:0] difference [0:3];
  logic [31:0] magnitude_result, corrected_result;

  assign signed_op = op == ALU_DIV || op == ALU_REM;
  assign rem_op = op == ALU_REM || op == ALU_REMU;
  assign magnitude_a = signed_op && a[31] ? -a : a;
  assign magnitude_b = signed_op && b[31] ? -b : b;

  // One shared four-step datapath serves both launch and later groups.
  // The subtraction's carry/borrow bit selects the restored remainder.
  assign step_divisor = busy_q ? divisor_q : magnitude_b;
  assign quotient_step[0] = busy_q ? quotient_q : magnitude_a;
  assign remainder_step[0] = busy_q ? remainder_q : 32'b0;
  for (genvar i = 0; i < 4; i++) begin : digit
    assign difference[i] = {remainder_step[i], quotient_step[i][31]}
                         - {1'b0, step_divisor};
    assign quotient_step[i+1] = {quotient_step[i][30:0], !difference[i][32]};
    assign remainder_step[i+1] = difference[i][32]
                              ? {remainder_step[i][30:0], quotient_step[i][31]}
                              : difference[i][31:0];
  end

  assign magnitude_result = rem_op_q ? remainder_step[4] : quotient_step[4];
  assign corrected_result = zero_divisor_q ? (rem_op_q ? dividend_q : 32'hffffffff)
                          : negate_q ? -magnitude_result : magnitude_result;
`endif

  // Both arithmetic builds use exactly this controller: no normalization,
  // special-case, formal-only, or correction shortcuts change the schedule.
  always_ff @(posedge clock) begin
    if (reset) begin
      busy_q <= 1'b0;
      group_q <= 3'b0;
      result_valid <= 1'b0;
      result <= 32'b0;
`ifdef RISCV_FORMAL_ALTOPS
      alt_result_q <= 32'b0;
`else
      divisor_q <= 32'b0;
      quotient_q <= 32'b0;
      remainder_q <= 32'b0;
      dividend_q <= 32'b0;
      rem_op_q <= 1'b0;
      negate_q <= 1'b0;
      zero_divisor_q <= 1'b0;
`endif
    end else begin
      if (result_valid && result_ready) result_valid <= 1'b0;
      if (accept) begin
        busy_q <= 1'b1;
        group_q <= 3'd1;
`ifdef RISCV_FORMAL_ALTOPS
        alt_result_q <= alt_result;
`else
        divisor_q <= magnitude_b;
        quotient_q <= quotient_step[4];
        remainder_q <= remainder_step[4];
        dividend_q <= a;
        rem_op_q <= rem_op;
        negate_q <= signed_op && (rem_op ? a[31] : (a[31] ^ b[31]));
        zero_divisor_q <= b == 32'b0;
`endif
      end else if (busy_q) begin
        group_q <= group_q + 3'd1;
`ifndef RISCV_FORMAL_ALTOPS
        quotient_q <= quotient_step[4];
        remainder_q <= remainder_step[4];
`endif
        if (group_q == 3'd7) begin
          busy_q <= 1'b0;
          result_valid <= 1'b1;
`ifdef RISCV_FORMAL_ALTOPS
          result <= alt_result_q;
`else
          result <= corrected_result;
`endif
        end
      end
    end
  end
endmodule
