// rtl/alu.sv
//
// RV32IM ALU with a product payload for EX/MEM and one shared radix-32
// divider. Capture normalized operands at t0; prepare widened multiples
// and a two-bit prefix at t1; select six five-bit digits at t2 through t7.
// Only registered quotient/remainder state feeds the completed result.
//
// RV32IM division semantics (overridden from straight `signed /`):
//   DIV  by 0       -> -1   (all ones)
//   DIVU by 0       -> 0xFFFFFFFF
//   DIV  INT_MIN/-1 -> INT_MIN  (no trap, defined overflow)
//   REM  by 0       -> dividend
//   REMU by 0       -> dividend
//   REM  INT_MIN/-1 -> 0
//
// Latency:        integer combinational, MUL selected after EX/MEM; DIV at t0,
//                 valid after t7, earliest result handshake at t8.
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module alu (
  input  logic        clock,
  input  logic        reset,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  // RV32M always uses the fully forwarded, registered source operands.
  input  logic [31:0] m_a,
  input  logic [31:0] m_b,
  output logic [31:0] out,
  output logic [65:0] product,
  input  logic        div_req_valid,
  output logic        div_req_ready,
  output logic        div_result_valid,
  input  logic        div_result_ready,
  output logic [31:0] div_result
);

  logic        [4:0]  shamt;

  // One signed 33x33 product supports all four multiply kinds. It feeds
  // only EX/MEM, never the ordinary ALU or EX-to-ID result mux.
`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] multiply_substitute;
  always_comb begin
    case (op)
      ALU_MUL:    multiply_substitute = (m_a + m_b) ^ 32'h5876063e;
      ALU_MULH:   multiply_substitute = (m_a + m_b) ^ 32'hf6583fb7;
      ALU_MULHU:  multiply_substitute = (m_a + m_b) ^ 32'h949ce5e8;
      ALU_MULHSU: multiply_substitute = (m_a - m_b) ^ 32'hecfbe137;
      default:    multiply_substitute = 32'b0;
    endcase
    product = op == ALU_MUL ? {34'b0, multiply_substitute}
                            : {2'b0, multiply_substitute, 32'b0};
  end
`else
  logic signed [32:0] multiply_a, multiply_b;
  assign multiply_a = $signed({((op == ALU_MULH || op == ALU_MULHSU) && m_a[31]), m_a});
  assign multiply_b = $signed({((op == ALU_MULH) && m_b[31]), m_b});
  assign product = multiply_a * multiply_b;
`endif

  always_comb begin
    shamt = b[4:0];

    case (op)
      ALU_ADD:    out = a + b;
      ALU_SUB:    out = a - b;
      ALU_AND:    out = a & b;
      ALU_OR:     out = a | b;
      ALU_XOR:    out = a ^ b;
      ALU_SLT:    out = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU:   out = {31'b0, a < b};
      ALU_SLL:    out = a << shamt;
      ALU_SRL:    out = a >> shamt;
      ALU_SRA:    out = $unsigned($signed(a) >>> shamt);
      ALU_LUI:    out = b;

      default:  out = 32'b0;
    endcase
  end

  logic busy_q, done_q;
  logic [2:0] iteration_q;

  assign div_req_ready = !busy_q && !done_q && !reset;
  // At t7 the final radix-32 digit enters the state registers. Completion is
  // sticky, and these registers freeze until the next accepted request.
  assign div_result_valid = done_q && !reset;

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result_q;
  assign div_result = alt_result_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      alt_result_q <= 32'b0;
    end else if (div_req_valid && div_req_ready) begin
      case (op)
        ALU_DIV:  alt_result_q <= (m_a - m_b) ^ 32'h7f8529ec;
        ALU_DIVU: alt_result_q <= (m_a - m_b) ^ 32'h10e8fd70;
        ALU_REM:  alt_result_q <= (m_a - m_b) ^ 32'h8da68fa5;
        ALU_REMU: alt_result_q <= (m_a - m_b) ^ 32'h3138d0e1;
        default:  alt_result_q <= 32'b0;
      endcase
    end
  end
`else
  logic [31:0] divisor_q, dividend_q, magnitude_q, quotient_q, remainder_q;
  logic quotient_negative_q, remainder_negative_q, want_remainder_q;
  logic zero_divisor_q;
  logic signed_op;
  logic [31:0] dividend_magnitude, divisor_magnitude;
  logic small_divisor;
  logic prepare;
  logic [1:0] prefix_quotient [0:2];
  logic [1:0] prefix_remainder [0:2];
  logic [1:0] prefix_shifted [0:1];
  logic [2:0] prefix_trial [0:1];
  logic [36:0] divisor_wide;
  logic [36:0] multiple_q [1:31];
  logic [36:0] digit_trial;
  // Bits 36:32 are discarded only after the full-width borrow decision.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [37:0] difference [1:31];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:1] subtract_ok;
  logic [31:0] digit_select;
  logic [36:0] masked_digit [0:31];
  logic [36:0] digit_or16 [0:15];
  logic [36:0] digit_or8 [0:7];
  logic [36:0] digit_or4 [0:3];
  logic [36:0] digit_or2 [0:1];
  logic [36:0] selected_digit;
  logic [31:0] magnitude;
  logic negate_result;

  assign signed_op = (op == ALU_DIV || op == ALU_REM);
  assign dividend_magnitude = signed_op && m_a[31] ? (32'b0 - m_a) : m_a;
  assign divisor_magnitude = signed_op && m_b[31] ? (32'b0 - m_b) : m_b;
  assign prepare = busy_q && iteration_q == 3'd0;
  assign small_divisor = (divisor_q[31:2] == 30'b0) &&
                         (divisor_q[1:0] != 2'b0);

  // Only two dividend bits enter at t1, so every shifted
  // prefix remainder fits in two bits. The third subtraction bit retains
  // borrow. A large divisor must never be truncated into this network.
  assign prefix_quotient[0] = magnitude_q[31:30];
  assign prefix_remainder[0] = 2'b0;
  for (genvar step = 0; step < 2; step++) begin : prefix_step
    assign prefix_shifted[step] = {prefix_remainder[step][0],
                                    prefix_quotient[step][1]};
    assign prefix_trial[step] = {1'b0, prefix_shifted[step]} -
                                {1'b0, divisor_q[1:0]};
    assign prefix_remainder[step+1] = prefix_trial[step][2]
                                      ? prefix_shifted[step] : prefix_trial[step][1:0];
    assign prefix_quotient[step+1] = {prefix_quotient[step][0], !prefix_trial[step][2]};
  end

  // Elaboration-only canonical signed digits. Positive terms are added in
  // ascending shift order, then negative terms subtracted in that order.
  function automatic [5:0] csd_mask(input integer coefficient, input logic negative);
    integer remaining, digit;
    begin
      remaining = coefficient;
      csd_mask = 6'b0;
      for (integer shift = 0; shift < 6; shift = shift + 1) begin
        digit = 0;
        if (remaining % 2 != 0) begin
          digit = 2 - (remaining % 4);
          csd_mask[shift] = negative ? digit == -1 : digit == 1;
          remaining = remaining - digit;
        end
        remaining = remaining >> 1;
      end
    end
  endfunction

  // Each t1 bank register is computed directly from the registered D.
  // No normalization or digit work feeds the t0 magnitude registers.
  assign divisor_wide = {5'b0, divisor_q};
  assign multiple_q[1] = divisor_wide;
  for (genvar k = 2; k <= 31; k++) begin : divisor_multiple
    localparam logic [5:0] POSITIVE = csd_mask(k, 1'b0);
    localparam logic [5:0] NEGATIVE = csd_mask(k, 1'b1);
    logic [36:0] multiple_d;
    always_comb begin
      multiple_d = 37'b0;
      for (integer shift = 0; shift < 6; shift = shift + 1)
        if (POSITIVE[shift]) multiple_d = multiple_d + (divisor_wide << shift);
      for (integer shift = 0; shift < 6; shift = shift + 1)
        if (NEGATIVE[shift]) multiple_d = multiple_d - (divisor_wide << shift);
    end
    always_ff @(posedge clock) begin
      if (reset)
        multiple_q[k] <= 37'b0;
      else if (prepare)
        multiple_q[k] <= multiple_d;
    end
  end

  // R < D implies T < 32*D. All 31 borrow decisions are independent.
  // Their monotonic success bits yield a mutually exclusive digit select.
  // D=0 selects digit 31; the registered zero-divisor override is authoritative.
  assign digit_trial = {remainder_q, quotient_q[31:27]};
  assign digit_select[0] = !subtract_ok[1];
  assign masked_digit[0] = {37{digit_select[0]}} & {digit_trial[31:0], 5'b0};
  for (genvar k = 1; k <= 31; k++) begin : digit_candidate
    assign difference[k] = {1'b0, digit_trial} - {1'b0, multiple_q[k]};
    assign subtract_ok[k] = !difference[k][37];
    if (k == 31) begin : last_digit
      assign digit_select[k] = subtract_ok[k];
    end else begin : middle_digit
      assign digit_select[k] = subtract_ok[k] && !subtract_ok[k+1];
    end
    assign masked_digit[k] = {37{digit_select[k]}} & {difference[k][31:0], k[4:0]};
  end
  // Balanced selection of the remainder and quotient digit together.
  for (genvar k = 0; k < 16; k++) begin : select16
    assign digit_or16[k] = masked_digit[2*k] | masked_digit[2*k+1];
  end
  for (genvar k = 0; k < 8; k++) begin : select8
    assign digit_or8[k] = digit_or16[2*k] | digit_or16[2*k+1];
  end
  for (genvar k = 0; k < 4; k++) begin : select4
    assign digit_or4[k] = digit_or8[2*k] | digit_or8[2*k+1];
  end
  for (genvar k = 0; k < 2; k++) begin : select2
    assign digit_or2[k] = digit_or4[2*k] | digit_or4[2*k+1];
  end
  assign selected_digit = digit_or2[0] | digit_or2[1];

  always_comb begin
    magnitude = want_remainder_q ? remainder_q : quotient_q;
    negate_result = want_remainder_q ? remainder_negative_q : quotient_negative_q;
    div_result = negate_result ? (32'b0 - magnitude) : magnitude;
    if (zero_divisor_q)
      div_result = want_remainder_q ? dividend_q : 32'hffffffff;
    // INT_MIN / -1 naturally gives magnitude 0x80000000, positive sign,
    // and remainder zero; no overflow exception or separate datapath.
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      divisor_q <= 32'b0;
      dividend_q <= 32'b0;
      magnitude_q <= 32'b0;
      quotient_q <= 32'b0;
      remainder_q <= 32'b0;
      quotient_negative_q <= 1'b0;
      remainder_negative_q <= 1'b0;
      want_remainder_q <= 1'b0;
      zero_divisor_q <= 1'b0;
    end else if (div_req_valid && div_req_ready) begin
      divisor_q <= divisor_magnitude;
      dividend_q <= m_a;
      magnitude_q <= dividend_magnitude;
      quotient_negative_q <= signed_op && (m_a[31] ^ m_b[31]);
      remainder_negative_q <= signed_op && m_a[31];
      want_remainder_q <= (op == ALU_REM || op == ALU_REMU);
      zero_divisor_q <= (m_b == 32'b0);
    end else if (prepare) begin
      quotient_q <= {magnitude_q[29:0], small_divisor ? prefix_quotient[2] : 2'b0};
      remainder_q <= {30'b0, small_divisor ? prefix_remainder[2] : magnitude_q[31:30]};
    end else if (busy_q) begin
      quotient_q <= {quotient_q[26:0], selected_digit[4:0]};
      remainder_q <= selected_digit[36:5];
    end
  end
`endif

  // Identical request/wait/completion timing in real and ALTOPS builds.
  always_ff @(posedge clock) begin
    if (reset) begin
      busy_q <= 1'b0;
      done_q <= 1'b0;
      iteration_q <= 3'b0;
    end else if (div_req_valid && div_req_ready) begin
      busy_q <= 1'b1;
      iteration_q <= 3'b0;
    end else if (busy_q) begin
      if (iteration_q == 3'd6) begin
        busy_q <= 1'b0;
        done_q <= 1'b1;
      end else begin
        iteration_q <= iteration_q + 3'd1;
      end
    end else if (done_q && div_result_ready) begin
      done_q <= 1'b0;
    end
  end

endmodule
