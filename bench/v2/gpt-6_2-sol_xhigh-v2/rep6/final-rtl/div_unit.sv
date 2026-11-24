// A blocking RV32M divider. Issue captures the operands, then each of eight
// cycles consumes four dividend bits. The last cycle can transfer directly.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        request_valid,
  output logic        request_ready,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        result_valid,
  input  logic        result_ready,
  output logic [31:0] result_magnitude,
  output logic        result_negate,
  output logic [31:0] saved_a,
  output logic [31:0] saved_b
);

  logic [3:0] rounds_left;
  logic issue;

  assign request_ready = (rounds_left == 4'd0);
  assign result_valid  = (rounds_left == 4'd1);
  assign issue         = request_valid && request_ready;

  always_ff @(posedge clock) begin
    if (reset)
      rounds_left <= 4'd0;
    else if (issue)
      rounds_left <= 4'd8;
    else if (!request_ready && (!result_valid || result_ready))
      rounds_left <= rounds_left - 4'd1;
  end

  always_ff @(posedge clock) begin
    if (issue) begin
      saved_a <= a;
      saved_b <= b;
    end
  end

`ifdef RISCV_FORMAL_ALTOPS
  logic [4:0] op_q;
  logic [31:0] difference;

  always_ff @(posedge clock) begin
    if (issue) op_q <= op;
  end

  assign difference = saved_a - saved_b;
  assign result_negate = 1'b0;
  always_comb begin
    case (op_q)
      ALU_DIV:  result_magnitude = difference ^ 32'h7f8529ec;
      ALU_DIVU: result_magnitude = difference ^ 32'h10e8fd70;
      ALU_REM:  result_magnitude = difference ^ 32'h8da68fa5;
      ALU_REMU: result_magnitude = difference ^ 32'h3138d0e1;
      default:  result_magnitude = 32'b0;
    endcase
  end
`else
  logic signed_op, want_remainder;
  logic a_negative, b_negative;
  logic [31:0] dividend, divisor;
  logic [31:0] divisor_q;
  logic setup;
  logic want_remainder_q, negate_result_q;

  // The shift register starts with the dividend and fills with quotient
  // digits from the low end as dividend digits leave from the high end.
  logic [31:0] quotient_q;
  // Every registered remainder follows a scanned prefix of at most 28 bits.
  logic [27:0] remainder_q;
  logic [3:0] leading_digit, leading_remainder, digit;
  logic [31:0] trial, residual, quotient_next;
  logic [35:0] divisor_once, divisor_twice, divisor_four, divisor_eight;
  logic [35:0] sum_three, carry_three;
  logic [35:0] odd_multiple_q [1:7];
  logic [31:0] candidate_residual [0:15];
  logic [31:0] pair_residual [0:7];
  logic [31:0] group_of_four_residual [0:3];
  logic [31:0] group_of_eight_residual [0:1];
  logic [16:0] fits;
  logic [15:0] selected;

  assign signed_op      = (op == ALU_DIV || op == ALU_REM);
  assign want_remainder = (op == ALU_REM || op == ALU_REMU);
  assign a_negative     = signed_op && a[31];
  assign b_negative     = signed_op && b[31];
  assign dividend       = a_negative ? -a : a;
  assign divisor        = b_negative ? -b : b;

  assign setup = (rounds_left == 4'd8);

  // The leading nibble starts with a zero remainder. Each trial is at
  // most four bits, and a divisor greater than 15 can never fit.
  function automatic [7:0] divide_nibble (
    input logic [3:0] nibble,
    input logic [3:0] divisor_low
  );
    logic [3:0] partial, narrow_trial, narrow_digit;
    logic [4:0] subtracted;
    begin
      partial = 4'b0;
      for (int bit_index = 3; bit_index >= 0; bit_index--) begin
        narrow_trial = {partial[2:0], nibble[bit_index]};
        subtracted = {1'b0, narrow_trial} - {1'b0, divisor_low};
        narrow_digit[bit_index] = !subtracted[4];
        partial = subtracted[4] ? narrow_trial : subtracted[3:0];
      end
      divide_nibble = {narrow_digit, partial};
    end
  endfunction

  assign {leading_digit, leading_remainder} = (|divisor_q[31:4])
      ? {4'b0, quotient_q[31:28]} : divide_nibble(quotient_q[31:28], divisor_q[3:0]);

  // Register the odd multiples alongside the leading digit. Carry-save
  // reduction leaves one carry-propagate sum for each multiple.
  function automatic [35:0] sum_terms (
    input logic [35:0] x, y, z
  );
    logic [35:0] sum, carry;
    begin
      sum = x ^ y ^ z;
      carry = ((x & y) | ((x | y) & z)) << 1;
      sum_terms = sum + carry;
    end
  endfunction

  assign divisor_once  = {4'b0, divisor_q};
  assign divisor_twice = divisor_once << 1;
  assign divisor_four  = divisor_once << 2;
  assign divisor_eight = divisor_once << 3;
  assign sum_three = divisor_twice ^ divisor_four ^ divisor_eight;
  assign carry_three = ((divisor_twice & divisor_four)
                     | ((divisor_twice | divisor_four) & divisor_eight)) << 1;

  always_ff @(posedge clock) begin
    if (setup) begin
      odd_multiple_q[1] <= divisor_once + divisor_twice;
      odd_multiple_q[2] <= divisor_once + divisor_four;
      odd_multiple_q[3] <= sum_terms(divisor_once, divisor_twice, divisor_four);
      odd_multiple_q[4] <= divisor_once + divisor_eight;
      odd_multiple_q[5] <= sum_terms(divisor_once, divisor_twice, divisor_eight);
      odd_multiple_q[6] <= sum_terms(divisor_once, divisor_four, divisor_eight);
      odd_multiple_q[7] <= sum_terms(divisor_once, sum_three, carry_three);
    end
  end

  // Each candidate sees the same trial. The upper multiple bits prevent
  // a wrapped subtraction from qualifying, and bit 32 reports borrow.
  assign trial = {remainder_q, quotient_q[31:28]};
  assign candidate_residual[0] = trial;
  assign fits[0] = 1'b1;
  assign fits[16] = 1'b0;
  for (genvar k = 1; k < 16; k++) begin : g_subtract
    // k = (2 * ODD_INDEX + 1) << SHIFT. Even multiples only need wiring.
    localparam integer SHIFT = (k % 2 != 0) ? 0 : (k % 4 != 0) ? 1
                             : (k % 8 != 0) ? 2 : 3;
    localparam integer ODD_INDEX = (k >> SHIFT) / 2;
    logic [35:0] multiple;
    logic [32:0] difference;
    if (ODD_INDEX == 0) begin : g_registered_divisor
      assign multiple = divisor_once << SHIFT;
    end else begin : g_registered_multiple
      assign multiple = odd_multiple_q[ODD_INDEX] << SHIFT;
    end
    assign difference = {1'b0, trial} - {1'b0, multiple[31:0]};
    assign fits[k] = !difference[32] && !(|multiple[35:32]);
    assign candidate_residual[k] = difference[31:0];
  end

  // Fits are monotone in digit order. Select the upper half of each
  // group when its lowest digit fits to keep the largest fitting digit.
  for (genvar k = 0; k < 8; k++) begin : g_residual_pairs
    assign pair_residual[k] = fits[2*k+1] ? candidate_residual[2*k+1]
                                         : candidate_residual[2*k];
  end
  for (genvar k = 0; k < 4; k++) begin : g_residual_groups_of_four
    assign group_of_four_residual[k] = fits[4*k+2] ? pair_residual[2*k+1]
                                                  : pair_residual[2*k];
  end
  for (genvar k = 0; k < 2; k++) begin : g_residual_groups_of_eight
    assign group_of_eight_residual[k] = fits[8*k+4] ? group_of_four_residual[2*k+1]
                                                   : group_of_four_residual[2*k];
  end
  assign residual = fits[8] ? group_of_eight_residual[1] : group_of_eight_residual[0];

  // Adjacent fit tests encode the quotient digit separately.
  assign selected = fits[15:0] & ~fits[16:1];
  always_comb begin
    digit = '0;
    for (int k = 0; k < 16; k++)
      digit |= {4{selected[k]}} & 4'(k);
  end

  // Deliver the eighth digit directly from the full-width stage.
  assign quotient_next    = {quotient_q[27:0], digit};
  assign result_magnitude = want_remainder_q ? residual : quotient_next;
  assign result_negate    = negate_result_q;

  always_ff @(posedge clock) begin
    if (issue) begin
      quotient_q       <= dividend;
      divisor_q        <= divisor;
      want_remainder_q <= want_remainder;
      // Zero divisor fits every trial: quotient digits are all ones and
      // the remainder is the dividend magnitude. Preserve that quotient
      // and restore the dividend sign for REM. INT_MIN/-1 wraps naturally.
      negate_result_q  <= want_remainder ? a_negative
                                        : (a_negative ^ b_negative) && (b != 32'b0);
    end else if (!request_ready && !result_valid) begin
      quotient_q  <= {quotient_q[27:0], setup ? leading_digit : digit};
      remainder_q <= setup ? {24'b0, leading_remainder} : residual[27:0];
    end
    // Hold the final step's inputs while the consumer waits. The result
    // and the saved operands stay stable until result_ready is asserted.
  end
`endif

endmodule
