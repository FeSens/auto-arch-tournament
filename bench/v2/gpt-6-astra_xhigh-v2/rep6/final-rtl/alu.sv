// rtl/alu.sv
//
// X arithmetic, launched exclusively by resolved ID/EX operand flops.
// Multiplication produces four signed limb products for EX/MEM. Division
// captures magnitudes at edge 0 and performs one radix-16 digit at edges
// 1..8. Edge 8 transfers the complete unsigned result; M corrects its sign.
// A blocked edge 8 saves the complete result exactly once.
//
// RV32IM division semantics (overridden from straight `signed /`):
//   DIV  by 0       -> -1   (all ones)
//   DIVU by 0       -> 0xFFFFFFFF
//   DIV  INT_MIN/-1 -> INT_MIN  (no trap, defined overflow)
//   REM  by 0       -> dividend
//   REMU by 0       -> dividend
//   REM  INT_MIN/-1 -> 0
//
// Latency: integer result / multiply partials combinational; division token
// after nine X clocks. M finishes registered partials before W capture.
`include "core_pkg.sv"
module alu (
  input  logic        clock,
  input  logic        reset,
  input  logic        div_request,
  input  logic        div_consume,
  output logic        div_busy,
  output logic        div_valid,
  output div_token_t div_token,
  output mul_partial_t mul_partial,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  logic        [4:0]  shamt;

`ifndef RISCV_FORMAL_ALTOPS
  logic signed [16:0] a_lo, a_hi, b_lo, b_hi;
  assign a_lo = $signed({1'b0, a[15:0]});
  assign b_lo = $signed({1'b0, b[15:0]});
  assign a_hi = $signed({a[31] && (op == ALU_MULH || op == ALU_MULHSU), a[31:16]});
  assign b_hi = $signed({b[31] && op == ALU_MULH, b[31:16]});
`endif

  always_comb begin
    mul_partial = '0;
    mul_partial.high_word = op != ALU_MUL;
`ifdef RISCV_FORMAL_ALTOPS
    case (op)
      ALU_MUL:    mul_partial.alt_result = (a + b) ^ 32'h5876063e;
      ALU_MULH:   mul_partial.alt_result = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  mul_partial.alt_result = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: mul_partial.alt_result = (a - b) ^ 32'hecfbe137;
      default:    mul_partial.alt_result = '0;
    endcase
`else
    mul_partial.ll = a_lo * b_lo;
    mul_partial.lh = a_lo * b_hi;
    mul_partial.hl = a_hi * b_lo;
    mul_partial.hh = a_hi * b_hi;
`endif
  end

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

  typedef enum logic [1:0] {DIV_IDLE, DIV_ROUND, DIV_DONE} div_state_t;
  div_state_t div_state;
  logic [2:0] round_q;
  logic final_round;
  // Availability depends only on registered state, never on consume.
  // The final round presents the complete unsigned result before edge 8.
  assign final_round = (div_state == DIV_ROUND && round_q == 3'd7);
  assign div_busy = (div_state != DIV_IDLE);
  assign div_valid = final_round || (div_state == DIV_DONE);

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result_q;
  always_comb begin
    div_token = '0;
    div_token.alt_result = alt_result_q;
  end
`else
  logic [33:0] divisor_q, divisor3_q;
  logic [31:0] divisor_magnitude, quotient_q, remainder_q;
  logic [33:0] divisor_extended;
  logic [35:0] divisor_wide;
  logic [35:0] divisor_odd_q [0:7];
  logic [35:0] divisor_odd [0:7];
  logic [35:0] divisor2, divisor4, divisor8;
  logic [35:0] sum11, carry11, sum13, carry13;
  logic [31:0] quotient_next, remainder_next;
  logic signed_op, negate_q, remainder_op_q;
  logic [35:0] trial;
  logic [35:0] multiple [1:15];
  // All bits participate in borrow decisions; selected remainders fit 32 bits.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [36:0] difference [1:15];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [15:0] select_digit;
  logic [35:0] candidate [0:15];
  logic [35:0] candidate_tree [1:31];
  logic [35:0] selected;

  assign signed_op = (op == ALU_DIV || op == ALU_REM);
  assign divisor_magnitude = signed_op && b[31] ? -b : b;
  // Normalize before widening. Even 15*(2^32-1) fits these 36 bits.
  // Multiple construction runs only on the request-capture path.
  assign divisor_extended = {2'b0, divisor_magnitude};
  assign divisor_wide = {4'b0, divisor_magnitude};
  assign divisor2 = divisor_wide << 1;
  assign divisor4 = divisor_wide << 2;
  assign divisor8 = divisor_wide << 3;
  assign divisor_odd[0] = divisor_wide;
  assign divisor_odd[1] = divisor2 + divisor_wide;
  assign divisor_odd[2] = divisor4 + divisor_wide;
  assign divisor_odd[3] = divisor8 - divisor_wide;
  assign divisor_odd[4] = divisor8 + divisor_wide;
  // Three operands reduce to two with bitwise carry-save logic, then one CPA.
  assign sum11 = divisor_wide ^ divisor2 ^ divisor8;
  assign carry11 = ((divisor_wide & divisor2)
                  | ((divisor_wide ^ divisor2) & divisor8)) << 1;
  assign divisor_odd[5] = sum11 + carry11;
  assign sum13 = divisor_wide ^ divisor4 ^ divisor8;
  assign carry13 = ((divisor_wide & divisor4)
                  | ((divisor_wide ^ divisor4) & divisor8)) << 1;
  assign divisor_odd[6] = sum13 + carry13;
  assign divisor_odd[7] = (divisor_wide << 4) - divisor_wide;
  always_comb begin
    div_token.quotient = final_round ? quotient_next : quotient_q;
    div_token.remainder = final_round ? remainder_next : remainder_q;
    div_token.divisor = divisor_q;
    div_token.divisor3 = divisor3_q;
    div_token.negate = negate_q;
    div_token.remainder_op = remainder_op_q;
  end
  assign trial = {remainder_q, quotient_q[31:28]};
  for (genvar k = 1; k <= 15; k++) begin : g_div_trial
    // Every even multiple is a constant shift of a captured odd multiple.
    if (k % 2 != 0) begin : g_odd
      assign multiple[k] = divisor_odd_q[k/2];
    end else if (k % 4 != 0) begin : g_twice
      assign multiple[k] = divisor_odd_q[k/4] << 1;
    end else if (k % 8 != 0) begin : g_four_times
      assign multiple[k] = divisor_odd_q[k/8] << 2;
    end else begin : g_eight_times
      assign multiple[k] = divisor_odd_q[0] << 3;
    end
    // Fifteen independent native subtractions; bit 36 is unsigned borrow.
    assign difference[k] = {1'b0, trial} - {1'b0, multiple[k]};
    if (k == 15) begin : g_last
      assign select_digit[k] = !difference[k][36];
    end else begin : g_threshold
      assign select_digit[k] = !difference[k][36] && difference[k+1][36];
    end
    assign candidate[k] = {36{select_digit[k]}} & {difference[k][31:0], 4'(k)};
  end
  assign select_digit[0] = difference[1][36];
  assign candidate[0] = {36{select_digit[0]}} & {trial[31:0], 4'b0};
  // Explicit balanced binary OR tree selects remainder and digit together.
  for (genvar k = 0; k < 16; k++) begin : g_leaf
    assign candidate_tree[16+k] = candidate[k];
  end
  for (genvar k = 1; k < 16; k++) begin : g_or
    assign candidate_tree[k] = candidate_tree[2*k] | candidate_tree[2*k+1];
  end
  assign selected = candidate_tree[1];
  // R<D implies T<16D, so the chosen remainder fits 32 bits. For D=0,
  // only digit 15 is selected and R retains the consumed dividend prefix.
  assign remainder_next = selected[35:4];
  assign quotient_next = {quotient_q[27:0], selected[3:0]};
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      div_state <= DIV_IDLE;
      round_q <= '0;
`ifdef RISCV_FORMAL_ALTOPS
      alt_result_q <= '0;
`else
      divisor_q <= '0;
      divisor3_q <= '0;
      for (int k = 0; k < 8; k++) divisor_odd_q[k] <= '0;
      quotient_q <= '0;
      remainder_q <= '0;
      negate_q <= 1'b0;
      remainder_op_q <= 1'b0;
`endif
    end else begin
      case (div_state)
        DIV_IDLE: if (div_request) begin
          div_state <= DIV_ROUND;
          round_q <= 3'd0;
`ifdef RISCV_FORMAL_ALTOPS
          case (op)
            ALU_DIV:  alt_result_q <= (a - b) ^ 32'h7f8529ec;
            ALU_DIVU: alt_result_q <= (a - b) ^ 32'h10e8fd70;
            ALU_REM:  alt_result_q <= (a - b) ^ 32'h8da68fa5;
            ALU_REMU: alt_result_q <= (a - b) ^ 32'h3138d0e1;
            default:  alt_result_q <= '0;
          endcase
`else
          quotient_q <= signed_op && a[31] ? -a : a;
          // Preserve the original packed token fields for internal monitors.
          divisor_q <= divisor_extended;
          divisor3_q <= divisor_extended + (divisor_extended << 1);
          for (int k = 0; k < 8; k++) divisor_odd_q[k] <= divisor_odd[k];
          remainder_q <= '0;
          remainder_op_q <= (op == ALU_REM || op == ALU_REMU);
          // A zero divisor naturally generates an all-ones quotient
          // and dividend remainder. Suppress quotient sign correction.
          negate_q <= signed_op && ((op == ALU_REM) ? a[31]
                                                   : ((a[31] ^ b[31]) && b != 0));
`endif
        end
        DIV_ROUND: begin
          if (final_round) begin
            // Edge 8: transfer the complete unsigned result, or save it ONCE.
            if (div_consume) begin
              div_state <= DIV_IDLE;
            end else begin
`ifndef RISCV_FORMAL_ALTOPS
              quotient_q <= quotient_next;
              remainder_q <= remainder_next;
`endif
              div_state <= DIV_DONE;
            end
          end else begin
`ifndef RISCV_FORMAL_ALTOPS
            quotient_q <= quotient_next;
            remainder_q <= remainder_next;
`endif
            round_q <= round_q + 3'd1;
          end
        end
        DIV_DONE: if (div_consume) div_state <= DIV_IDLE;
        default: div_state <= DIV_IDLE;
      endcase
    end
  end

endmodule
