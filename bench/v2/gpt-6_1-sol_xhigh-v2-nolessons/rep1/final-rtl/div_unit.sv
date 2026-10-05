// Four-bit launch, six-bit narrow bootstrap/preparation, five four-bit
// body clocks, then independent held-state terminal two-bit publication.
module div_unit (
  input logic clock, reset, start,
  input logic [4:0] op,
  input logic [31:0] a, b,
  input logic consume,
  output logic busy, result_valid,
  output logic [31:0] result
);
  localparam logic [1:0] IDLE = 0, RUN = 1, READY = 2;
  logic [1:0] state_q;
  logic [2:0] group_q;
`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_q;
  assign result = alt_q;
`else
  logic [31:0] quotient_q, remainder_q, divisor_q;
  logic quotient_neg_q, remainder_neg_q, select_rem_q;
  logic signed_op, negative_a, negative_b, small_divisor;
  logic [3:0] prefix, small_magnitude;
  logic [27:0] magnitude_low;
  logic [1:0] lookup_quotient, lookup_remainder;
  logic [3:0] prefix_quotient, prefix_remainder;
  logic [5:0] prefix_window, prefix_once, prefix_twice, prefix_triple;
  logic [6:0] prefix_diff [1:3] /* verilator split_var */;
  logic prefix_ok1, prefix_ok2, prefix_ok3;
  logic [3:0] prefix_mask;
  logic [9:0] narrow_magnitude;
  logic [12:0] narrow_base, narrow_triple_q, narrow_five_q, narrow_seven_q;
  logic [12:0] narrow_once, narrow_twice, narrow_four, narrow_six;
  logic [9:0] narrow_r [0:2] /* verilator split_var */;
  logic [2:0] narrow_digit [0:1] /* verilator split_var */;
  logic [31:0] first_quotient, first_remainder;
  logic [31:0] run_q [0:2] /* verilator split_var */;
  logic [31:0] run_r [0:2] /* verilator split_var */;
  logic [33:0] divisor_once, divisor_twice;
  logic [33:0] triple_divisor_q;
  logic [33:0] final_window;
  logic [34:0] final_diff [1:3] /* verilator split_var */;
  logic [3:0] final_mask;
  logic final_ok1, final_ok2, final_ok3;
  logic [31:0] positive_remainder [0:3] /* verilator split_var */;
  logic [31:0] negative_remainder [0:3] /* verilator split_var */;
  logic [31:0] final_candidate [0:3] /* verilator split_var */;
  logic quotient_positive, quotient_negative;
  assign signed_op = op == ALU_DIV || op == ALU_REM;
  assign negative_a = signed_op && a[31];
  assign negative_b = signed_op && b[31];
  // Compute the high magnitude nibble without a 32-bit negate carry chain.
  assign prefix = negative_a ? (~a[31:28] + 4'(a[27:0] == 0)) : a[31:28];
  assign magnitude_low = negative_a ? (28'd0 - a[27:0]) : a[27:0];
  assign small_divisor = negative_b
    ? (&b[31:4] && b[3:0] != 0) : (b[31:4] == 0);
  assign small_magnitude = negative_b ? (4'd0 - b[3:0]) : b[3:0];
  // First pair is an exact divmod lookup for D=0..3; larger D cannot
  // subtract from a two-bit prefix. The second pair uses parallel trials.
  always_comb begin
    lookup_quotient = 0;
    lookup_remainder = prefix[3:2];
    // The large-divisor bypass is applied only after this independent
    // lookup/cell bank, keeping the raw high-bit reduction out of its trials.
    case (small_magnitude)
        0: lookup_quotient = 2'b11;
        1: begin
          lookup_quotient = prefix[3:2];
          lookup_remainder = 0;
        end
        2: begin
          lookup_quotient = {1'b0, prefix[3]};
          lookup_remainder = {1'b0, prefix[2]};
        end
        3: begin
          lookup_quotient = {1'b0, &prefix[3:2]};
          lookup_remainder = &prefix[3:2] ? 2'b00 : prefix[3:2];
        end
        default: ;
    endcase
  end
  assign prefix_window = {2'd0, lookup_remainder, prefix[1:0]};
  assign prefix_once = {2'd0, small_magnitude};
  assign prefix_twice = {1'd0, small_magnitude, 1'b0};
  assign prefix_triple = prefix_once + prefix_twice;
  assign prefix_diff[1] = {1'b0, prefix_window} - {1'b0, prefix_once};
  assign prefix_diff[2] = {1'b0, prefix_window} - {1'b0, prefix_twice};
  assign prefix_diff[3] = {1'b0, prefix_window} - {1'b0, prefix_triple};
  assign prefix_ok1 = !prefix_diff[1][6];
  assign prefix_ok2 = !prefix_diff[2][6];
  assign prefix_ok3 = !prefix_diff[3][6];
  assign prefix_mask = {prefix_ok3, prefix_ok2 & !prefix_ok3,
                        prefix_ok1 & !prefix_ok2, !prefix_ok1};
  assign prefix_quotient = small_divisor
    ? {lookup_quotient, prefix_ok2, prefix_ok3 | (prefix_ok1 & !prefix_ok2)} : 4'd0;
  assign prefix_remainder = small_divisor
    ? (({4{prefix_mask[0]}} & prefix_window[3:0]) |
       ({4{prefix_mask[1]}} & prefix_diff[1][3:0]) |
       ({4{prefix_mask[2]}} & prefix_diff[2][3:0]) |
       ({4{prefix_mask[3]}} & prefix_diff[3][3:0])) : prefix;

  // Expensive bootstrap multiples are captured at L directly from raw b.
  // This ten-bit negate is independent of both full D and prefix trials.
  assign narrow_magnitude = negative_b ? (10'd0 - b[9:0]) : b[9:0];
  assign narrow_base = {3'd0, narrow_magnitude};
  assign narrow_once = {3'd0, divisor_q[9:0]};
  assign narrow_twice = {2'd0, divisor_q[9:0], 1'b0};
  assign narrow_four = {1'd0, divisor_q[9:0], 2'b0};
  assign narrow_six = narrow_triple_q << 1;

  function automatic [12:0] radix8_digit (
    input logic [6:0] r,
    input logic [2:0] bits_in,
    input logic [12:0] d1, d2, d3, d4, d5, d6, d7
  );
    logic [9:0] window, restored;
    logic [12:0] multiple [1:7];
    logic [10:0] diff [1:7];
    logic [7:1] ok;
    logic [7:0] mask;
    logic [2:0] digit;
    begin
      // Both windows contain at most the first ten dividend bits.
      window = {r, bits_in};
      multiple[1] = d1;
      multiple[2] = d2;
      multiple[3] = d3;
      multiple[4] = d4;
      multiple[5] = d5;
      multiple[6] = d6;
      multiple[7] = d7;
      for (integer j = 1; j <= 7; j = j + 1) begin
        diff[j] = {1'b0, window} - {1'b0, multiple[j][9:0]};
        // Never treat a truncated multiple >=1024 as an eligible trial.
        ok[j] = multiple[j][12:10] == 0 && !diff[j][10];
      end
      mask[0] = !ok[1];
      for (integer j = 1; j < 7; j = j + 1)
        mask[j] = ok[j] && !ok[j+1];
      mask[7] = ok[7];
      // Balanced masked OR banks avoid a serial seven-way selection chain.
      restored = ((({10{mask[0]}} & window) |
                   ({10{mask[1]}} & diff[1][9:0])) |
                  (({10{mask[2]}} & diff[2][9:0]) |
                   ({10{mask[3]}} & diff[3][9:0]))) |
                 ((({10{mask[4]}} & diff[4][9:0]) |
                   ({10{mask[5]}} & diff[5][9:0])) |
                  (({10{mask[6]}} & diff[6][9:0]) |
                   ({10{mask[7]}} & diff[7][9:0])));
      digit = {((mask[4] | mask[5]) | (mask[6] | mask[7])),
               ((mask[2] | mask[3]) | (mask[6] | mask[7])),
               ((mask[1] | mask[3]) | (mask[5] | mask[7]))};
      radix8_digit = {digit, restored};
    end
  endfunction
  assign narrow_r[0] = {6'd0, remainder_q[3:0]};
  for (genvar s = 0; s < 2; s++) begin : g_prefix
    assign {narrow_digit[s], narrow_r[s+1]} = radix8_digit(
      narrow_r[s][6:0], quotient_q[31-3*s -: 3], narrow_once, narrow_twice,
      narrow_triple_q, narrow_four, narrow_five_q, narrow_six, narrow_seven_q);
  end
  assign first_quotient = {quotient_q[25:0],
    ({narrow_digit[0], narrow_digit[1]} & {6{divisor_q[31:10] == 0}})};
  assign first_remainder = (divisor_q[31:10] != 0)
    ? {22'd0, remainder_q[3:0], quotient_q[31:26]} : {22'd0, narrow_r[2]};

  // Multiples retain all high bits. Only 3D needs arithmetic, registered
  // alongside the prefix at L+1 rather than in launch or RUN feedback.
  assign divisor_once = {2'b0, divisor_q};
  assign divisor_twice = {1'b0, divisor_q, 1'b0};
  assign run_q[0] = quotient_q;
  assign run_r[0] = remainder_q;
  function automatic [63:0] radix4_digit (
    input logic [31:0] q, r,
    input logic [33:0] d1, d2, d3
  );
    logic [33:0] window;
    // Bits 33:32 participate in borrow propagation; a restored R fits 32.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [34:0] diff1, diff2, diff3;
    /* verilator lint_on UNUSEDSIGNAL */
    logic ok1, ok2, ok3;
    logic [3:0] mask;
    logic [31:0] restored;
    begin
      window = {r, q[31:30]};
      diff1 = {1'b0, window} - {1'b0, d1};
      diff2 = {1'b0, window} - {1'b0, d2};
      diff3 = {1'b0, window} - {1'b0, d3};
      ok1 = !diff1[34];
      ok2 = !diff2[34];
      ok3 = !diff3[34];
      mask = {ok3, ok2 & !ok3, ok1 & !ok2, !ok1};
      restored = ({32{mask[0]}} & window[31:0]) |
                 ({32{mask[1]}} & diff1[31:0]) |
                 ({32{mask[2]}} & diff2[31:0]) |
                 ({32{mask[3]}} & diff3[31:0]);
      radix4_digit = {{q[29:0], ok2, ok3 | (ok1 & !ok2)}, restored};
    end
  endfunction
  for (genvar s = 0; s < 2; s++) begin : g_run
    assign {run_q[s+1], run_r[s+1]} = radix4_digit(
      run_q[s], run_r[s], divisor_once, divisor_twice, triple_divisor_q);
  end

  // Terminal trials read held thirty-bit state directly, independently
  // of the prefix/body mux and both feedback cells. Each constant digit
  // prepares its signed architectural result before the late borrow masks.
  assign final_window = {remainder_q, quotient_q[31:30]};
  assign final_diff[1] = {1'b0, final_window} - {1'b0, divisor_once};
  assign final_diff[2] = {1'b0, final_window} - {1'b0, divisor_twice};
  assign final_diff[3] = {1'b0, final_window} - {1'b0, triple_divisor_q};
  assign final_ok1 = !final_diff[1][34];
  assign final_ok2 = !final_diff[2][34];
  assign final_ok3 = !final_diff[3][34];
  assign final_mask = {final_ok3, final_ok2 & !final_ok3,
                       final_ok1 & !final_ok2, !final_ok1};
  assign positive_remainder[0] = final_window[31:0];
  assign negative_remainder[0] = 32'd0 - final_window[31:0];
  assign negative_remainder[1] = divisor_q - final_window[31:0];
  assign negative_remainder[2] = divisor_twice[31:0] - final_window[31:0];
  assign negative_remainder[3] = triple_divisor_q[31:0] - final_window[31:0];
  assign quotient_positive = !select_rem_q & !quotient_neg_q;
  assign quotient_negative = !select_rem_q & quotient_neg_q;
  for (genvar k = 0; k < 4; k++) begin : g_terminal
    logic [31:0] positive_quotient, negative_quotient;
    logic [31:0] signed_remainder;
    if (k != 0) begin : g_nonzero
      assign positive_remainder[k] = final_diff[k][31:0];
      assign negative_quotient = {~quotient_q[29:0], (2'd0 - 2'(k))};
    end else begin : g_zero
      assign negative_quotient = {(30'd0 - quotient_q[29:0]), 2'b00};
    end
    assign positive_quotient = {quotient_q[29:0], 2'(k)};
    assign signed_remainder = remainder_neg_q ? negative_remainder[k] : positive_remainder[k];
    assign final_candidate[k] = ({32{quotient_positive}} & positive_quotient) |
                               ({32{quotient_negative}} & negative_quotient) |
                               ({32{select_rem_q}} & signed_remainder);
  end
  assign result = ({32{final_mask[0]}} & final_candidate[0]) |
                  ({32{final_mask[1]}} & final_candidate[1]) |
                  ({32{final_mask[2]}} & final_candidate[2]) |
                  ({32{final_mask[3]}} & final_candidate[3]);
`endif
  assign busy = state_q != IDLE;
  assign result_valid = state_q == READY;
  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      group_q <= 0;
`ifdef RISCV_FORMAL_ALTOPS
      alt_q <= 0;
`else
      quotient_q <= 0;
      remainder_q <= 0;
      divisor_q <= 0;
      triple_divisor_q <= 0;
      narrow_triple_q <= 0;
      narrow_five_q <= 0;
      narrow_seven_q <= 0;
      quotient_neg_q <= 0;
      remainder_neg_q <= 0;
      select_rem_q <= 0;
`endif
    end else if (start && (state_q == IDLE || (state_q == READY && consume))) begin
      state_q <= RUN;
      group_q <= 0;
`ifdef RISCV_FORMAL_ALTOPS
      case (op)
        ALU_DIV: alt_q <= (a - b) ^ 32'h7f8529ec;
        ALU_DIVU: alt_q <= (a - b) ^ 32'h10e8fd70;
        ALU_REM: alt_q <= (a - b) ^ 32'h8da68fa5;
        ALU_REMU: alt_q <= (a - b) ^ 32'h3138d0e1;
        default: alt_q <= 0;
      endcase
`else
      quotient_q <= {magnitude_low, prefix_quotient};
      remainder_q <= {28'd0, prefix_remainder};
      divisor_q <= negative_b ? (32'd0 - b) : b;
      narrow_triple_q <= narrow_base + (narrow_base << 1);
      narrow_five_q <= narrow_base + (narrow_base << 2);
      narrow_seven_q <= (narrow_base << 3) - narrow_base;
      quotient_neg_q <= signed_op && (a[31] ^ b[31]) && b != 0;
      remainder_neg_q <= negative_a;
      select_rem_q <= op == ALU_REM || op == ALU_REMU;
`endif
    end else begin
      case (state_q)
        RUN: begin
`ifndef RISCV_FORMAL_ALTOPS
          if (group_q == 0) begin
            triple_divisor_q <= divisor_once + divisor_twice;
            quotient_q <= first_quotient;
            remainder_q <= first_remainder;
          end else begin
            quotient_q <= run_q[2];
            remainder_q <= run_r[2];
          end
`endif
          if (group_q == 5) state_q <= READY;
          else group_q <= group_q + 1'b1;
        end
        READY: if (consume) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
