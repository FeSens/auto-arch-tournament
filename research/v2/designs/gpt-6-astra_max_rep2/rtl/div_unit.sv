// Shared RV32M divider: idle-edge four-bit magnitude prefix, seven
// four-bit wide recurrence edges, then one sign-correction edge. Response
// acceptance stays on the eighth post-request edge. The terminal interval
// uses only registered magnitudes and flags; that result is registered on
// its closing edge, with response-valid held only if blocked. The data
// register also serves as EX/MEM's divide bank and survives consumption
// and the next request. No operand-dependent shortcuts or cooldown cycles.
// Reset cancels both an in-flight request and an unconsumed response.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        req_valid,
  output logic        req_ready,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        resp_valid,
  input  logic        resp_ready,
  output logic [31:0] result,
  output logic [31:0] registered_result
);
  logic       busy_q;
  logic [2:0] count_q;
  logic       final_cycle, held_q;
  logic [31:0] result_q, completed_result;

  assign final_cycle = busy_q && (count_q == 3'd7);
  assign resp_valid = held_q || final_cycle;
  assign result = final_cycle ? completed_result : result_q;
  // No terminal bypass here: EX selects this bank only after the edge
  // that captures both completed_result and the accepting metadata.
  assign registered_result = result_q;
  assign req_ready = !reset && !busy_q && (!held_q || resp_ready);

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result_q;
  assign completed_result = alt_result_q;
`else
  logic [31:0] quotient_q, remainder_q, divisor_q, dividend_q;
  logic dividend_negative_q, divisor_negative_q, zero_divisor_q, want_rem_q;
  logic signed_op;
  logic [31:0] dividend_magnitude, divisor_magnitude;
  logic [3:0] prefix_quotient [0:4];
  logic [3:0] prefix_remainder [0:4];
  logic [4:0] prefix_trial [0:3];
  logic [4:0] prefix_difference [0:3];
  logic [3:0] initial_quotient, initial_remainder;
  logic [31:0] quotient_step [0:4];
  logic [31:0] remainder_step [0:4];
  logic [32:0] trial [0:3];
  logic [32:0] difference [0:3];
  logic [31:0] quotient_signed, remainder_signed;

  assign signed_op = (op == ALU_DIV || op == ALU_REM);
  assign dividend_magnitude = (signed_op && a[31]) ? (32'b0 - a) : a;
  assign divisor_magnitude = (signed_op && b[31]) ? (32'b0 - b) : b;

  // Only the leading nibble is consumed on the request edge. Its value
  // is at most 15, so any divisor >= 16 leaves quotient zero/remainder P.
  // Otherwise use ordinary restoring steps with a five-bit subtract:
  // the trial never exceeds 15 in these first four steps, so bit 4 is
  // an explicit borrow, including D=0 (whose final result is overridden).
  always_comb begin
    prefix_quotient[0] = dividend_magnitude[31:28];
    prefix_remainder[0] = 4'b0;
    for (int step = 0; step < 4; step++) begin
      prefix_trial[step] = {prefix_remainder[step], prefix_quotient[step][3]};
      prefix_difference[step] = prefix_trial[step] - {1'b0, divisor_magnitude[3:0]};
      prefix_remainder[step+1] = prefix_difference[step][4]
                              ? prefix_trial[step][3:0] : prefix_difference[step][3:0];
      prefix_quotient[step+1] = {prefix_quotient[step][2:0], !prefix_difference[step][4]};
    end
    initial_quotient = (|divisor_magnitude[31:4]) ? 4'b0 : prefix_quotient[4];
    initial_remainder = (|divisor_magnitude[31:4])
                      ? dividend_magnitude[31:28] : prefix_remainder[4];
  end

  // Each step shifts in one dividend bit, subtracts the divisor, and
  // restores on borrow. Keep the extra bit: bit 31 is data, not borrow,
  // including when either unsigned operand has its high bit set.
  always_comb begin
    quotient_step[0] = quotient_q;
    remainder_step[0] = remainder_q;
    for (int step = 0; step < 4; step++) begin
      trial[step] = {remainder_step[step], quotient_step[step][31]};
      difference[step] = trial[step] - {1'b0, divisor_q};
      remainder_step[step+1] = difference[step][32]
                            ? trial[step][31:0] : difference[step][31:0];
      quotient_step[step+1] = {quotient_step[step][30:0], !difference[step][32]};
    end
  end

  // Seven recurrence edges finish the remaining 28 dividend bits.
  // Q/R hold during interval eight: no recurrence or live-operand cone
  // feeds this correction path or the completion bank's terminal edge.
  always_comb begin
    quotient_signed = (dividend_negative_q ^ divisor_negative_q)
                    ? (32'b0 - quotient_q) : quotient_q;
    remainder_signed = dividend_negative_q
                     ? (32'b0 - remainder_q) : remainder_q;
    // Magnitude arithmetic naturally preserves INT_MIN / -1 and its
    // zero remainder. Zero divisor overrides sign correction.
    completed_result = zero_divisor_q ? (want_rem_q ? dividend_q : 32'hffffffff)
                                     : (want_rem_q ? remainder_signed : quotient_signed);
  end
`endif

  // Arithmetic storage is unowned while idle, including beneath a held
  // response. Every accepted request occurs on an idle edge and captures
  // that edge's exact operands; request qualification only owns control.
`ifdef RISCV_FORMAL_ALTOPS
  always_ff @(posedge clock) begin
    if (reset) begin
      alt_result_q <= 32'b0;
    end else if (!busy_q) begin
      case (op)
        ALU_DIV:  alt_result_q <= (a - b) ^ 32'h7f8529ec;
        ALU_DIVU: alt_result_q <= (a - b) ^ 32'h10e8fd70;
        ALU_REM:  alt_result_q <= (a - b) ^ 32'h8da68fa5;
        ALU_REMU: alt_result_q <= (a - b) ^ 32'h3138d0e1;
        default:  alt_result_q <= 32'b0;
      endcase
    end
  end
`else
  always_ff @(posedge clock) begin
    if (reset) begin
      quotient_q <= 32'b0;
      remainder_q <= 32'b0;
    end else if (!busy_q) begin
      quotient_q <= {dividend_magnitude[27:0], initial_quotient};
      remainder_q <= {28'b0, initial_remainder};
    end else if (!final_cycle) begin
      quotient_q <= quotient_step[4];
      remainder_q <= remainder_step[4];
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      divisor_q <= 32'b0;
      dividend_q <= 32'b0;
      dividend_negative_q <= 1'b0;
      divisor_negative_q <= 1'b0;
      zero_divisor_q <= 1'b0;
      want_rem_q <= 1'b0;
    end else if (!busy_q) begin
      divisor_q <= divisor_magnitude;
      dividend_q <= a;
      dividend_negative_q <= signed_op && a[31];
      divisor_negative_q <= signed_op && b[31];
      zero_divisor_q <= (b == 32'b0);
      want_rem_q <= (op == ALU_REM || op == ALU_REMU);
    end
  end
`endif

  // The protocol and completion bank retain their original write edges.
  // In particular, idle captures cannot start work or alter result_q.
  always_ff @(posedge clock) begin
    if (reset) begin
      busy_q <= 1'b0;
      count_q <= 3'b0;
      held_q <= 1'b0;
      result_q <= 32'b0;
    end else begin
      if (resp_valid && resp_ready)
        held_q <= 1'b0;

      if (req_valid && req_ready) begin
        busy_q <= 1'b1;
        count_q <= 3'b0;
      end else if (busy_q) begin
        count_q <= count_q + 3'd1;
        if (final_cycle) begin
          busy_q <= 1'b0;
          held_q <= !resp_ready;
          result_q <= completed_result;
        end
      end
    end
  end
endmodule
