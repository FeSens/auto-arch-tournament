// Shared RV32M divider with a fixed request-to-result latency.
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
  output logic [31:0] result
);

  localparam logic [3:0] IDLE = 4'd0, PREFIX = 4'd1, DONE = 4'd8;
  logic [3:0] phase_q;
  logic       capture;

  assign request_ready = (phase_q == IDLE);
  assign capture       = request_valid && request_ready;
  assign result_valid  = (phase_q == DONE);

  // Consume the top byte on the first work edge, then one nibble per edge
  // for six edges. The result can transfer eight edges after capture.
  always_ff @(posedge clock) begin
    if (reset) begin
      phase_q <= IDLE;
    end else if (capture) begin
      phase_q <= PREFIX;
    end else if (phase_q == DONE) begin
      if (result_ready)
        phase_q <= IDLE;
    end else if (phase_q != IDLE) begin
      phase_q <= phase_q + 4'd1;
    end
  end

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] salt, alt_result_q;
  always_comb begin
    case (op)
      ALU_DIV:  salt = 32'h7f8529ec;
      ALU_DIVU: salt = 32'h10e8fd70;
      ALU_REM:  salt = 32'h8da68fa5;
      ALU_REMU: salt = 32'h3138d0e1;
      default:  salt = '0;
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      result <= '0;
    end else begin
      if (capture)
        alt_result_q <= (a - b) ^ salt;
      if (phase_q == DONE - 4'd1)
        result <= alt_result_q;
    end
  end
`else
  logic        want_remainder, negative_a, negative_b;
  logic        divisor_nibble, divisor_byte_q;
  logic [27:0] magnitude_a_low;
  logic [31:0] magnitude_b;
  logic        remainder_q, negate_q;
  logic [31:0] partial_remainder_q, divisor_q, magnitude_result;
  // Quotient digits replace the consumed dividend bits as the register shifts.
  logic [31:0] dividend_quotient_q;
  logic [35:0] divisor, divisor_2, divisor_4, divisor_8;
  logic [35:0] odd_multiple [0:7];
  logic [35:0] odd_multiple_q [0:7];

  assign want_remainder = (op == ALU_REM || op == ALU_REMU);
  assign negative_a = (op == ALU_DIV || op == ALU_REM) && a[31];
  assign negative_b = (op == ALU_DIV || op == ALU_REM) && b[31];
  assign magnitude_a_low = negative_a ? -a[27:0] : a[27:0];
  assign magnitude_b = negative_b ? -b : b;
  // Test the original divisor in parallel with the magnitude adder. For
  // negative inputs exclude the exact cutoff (-16 or -256).
  assign divisor_nibble = negative_b ? (&b[31:4] && |b[3:0]) : !(|b[31:4]);
  assign divisor   = {4'b0, divisor_q};
  assign divisor_2 = divisor << 1;
  assign divisor_4 = divisor << 2;
  assign divisor_8 = divisor << 3;

  // Carry-save compress the three terms of 11D and 13D before adding.
  function automatic logic [35:0] sum_three(
    input logic [35:0] x, y, z
  );
    sum_three = (x ^ y ^ z) + (((x & y) | ((x | y) & z)) << 1);
  endfunction

  assign odd_multiple[0] = divisor;
  assign odd_multiple[1] = divisor_2 + divisor;
  assign odd_multiple[2] = divisor_4 + divisor;
  assign odd_multiple[3] = divisor_8 - divisor;
  assign odd_multiple[4] = divisor_8 + divisor;
  assign odd_multiple[5] = sum_three(divisor_8, divisor_2, divisor);
  assign odd_multiple[6] = sum_three(divisor_8, divisor_4, divisor);
  assign odd_multiple[7] = (divisor << 4) - divisor;

  assign odd_multiple_q[0] = divisor;
  for (genvar odd = 1; odd < 8; odd++) begin : gen_odd_multiple
    always_ff @(posedge clock) begin
      if (phase_q == PREFIX)
        odd_multiple_q[odd] <= odd_multiple[odd];
    end
  end

  // Each constant table maps the first nibble to {remainder, quotient}.
  function automatic logic [127:0] first_nibble_table(input int unsigned divisor_value);
    for (int unsigned nibble = 0; nibble < 16; nibble++) begin
      if (divisor_value == 0)
        first_nibble_table[8*nibble +: 8] = {4'(nibble), 4'hf};
      else
        first_nibble_table[8*nibble +: 8] =
            {4'(nibble % divisor_value), 4'(nibble / divisor_value)};
    end
  endfunction

  logic [3:0] first_nibble;
  logic [3:0] first_remainder_q;
  logic [7:0] first_entry [0:15];
  logic [7:0] first_result, prefix_trial;
  // The carry into the top nibble of a negative magnitude depends only
  // on whether the lower 28 bits are zero.
  assign first_nibble = (a[31:28] ^ {4{negative_a}}) + {3'b0, negative_a && !(|a[27:0])};

  for (genvar d = 0; d < 16; d++) begin : gen_first_nibble
    localparam logic [127:0] TABLE = first_nibble_table(d);
    assign first_entry[d] = TABLE[8*first_nibble +: 8];
  end

  assign first_result = divisor_nibble ? first_entry[magnitude_b[3:0]]
                                       : {first_nibble, 4'b0};
  assign prefix_trial = {first_remainder_q, dividend_quotient_q[27:24]};

  logic [35:0] trial;
  logic [16:0] prefix_borrow, borrow;
  logic [15:0] prefix_take, take;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [12:0] prefix_diff [0:15];
  logic [36:0] diff [0:15];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [7:0]  prefix_remainder;
  logic [31:0] next_remainder;
  logic [3:0]  prefix_digit, quotient_digit;

  assign trial = {partial_remainder_q, dividend_quotient_q[31:28]};
  assign prefix_diff[0] = {5'b0, prefix_trial};
  assign diff[0] = {1'b0, trial};
  assign prefix_borrow[16] = 1'b1;
  assign borrow[16] = 1'b1;

  for (genvar digit = 1; digit < 16; digit++) begin : gen_trial_subtract
    localparam int SHIFT = (digit % 2 != 0) ? 0 : (digit % 4 != 0) ? 1 :
                           (digit % 8 != 0) ? 2 : 3;
    localparam int ODD_FACTOR = digit >> SHIFT;
    logic [11:0] prefix_multiple;
    logic [35:0] multiple;
    assign prefix_multiple = (divisor_q[7:0] * 12'(ODD_FACTOR)) << SHIFT;
    assign multiple = odd_multiple_q[ODD_FACTOR / 2] << SHIFT;
    assign prefix_diff[digit] = {5'b0, prefix_trial} - {1'b0, prefix_multiple};
    assign diff[digit] = {1'b0, trial} - {1'b0, multiple};
  end

  // Adjacent borrow bits select the largest fitting multiple. For a zero
  // divisor every difference equals the trial and only digit 15 is selected.
  for (genvar digit = 0; digit < 16; digit++) begin : gen_digit_select
    assign prefix_borrow[digit] = prefix_diff[digit][12];
    assign borrow[digit] = diff[digit][36];
    assign prefix_take[digit] = prefix_borrow[digit+1] && !prefix_borrow[digit];
    assign take[digit] = borrow[digit+1] && !borrow[digit];
  end

  always_comb begin
    prefix_remainder = prefix_trial;
    prefix_digit = '0;
    // The full byte is smaller than any divisor above 255.
    if (divisor_byte_q) begin
      prefix_remainder = '0;
      for (int digit = 0; digit < 16; digit++) begin
        prefix_remainder |= {8{prefix_take[digit]}} & prefix_diff[digit][7:0];
        prefix_digit     |= {4{prefix_take[digit]}} & 4'(digit);
      end
    end
  end

  always_comb begin
    next_remainder = '0;
    quotient_digit = '0;
    for (int digit = 0; digit < 16; digit++) begin
      // For nonzero D, the selected difference is less than D.
      next_remainder |= {32{take[digit]}} & diff[digit][31:0];
      quotient_digit |= {4{take[digit]}} & 4'(digit);
    end
  end

  always_ff @(posedge clock) begin
    if (capture) begin
      dividend_quotient_q <= {first_result[3:0], magnitude_a_low};
      first_remainder_q   <= first_result[7:4];
      divisor_q           <= magnitude_b;
      divisor_byte_q      <= negative_b ? (&b[31:8] && |b[7:0]) : !(|b[31:8]);
      remainder_q         <= want_remainder;
      // A zero divisor leaves the dividend magnitude as the remainder.
      // Suppress quotient negation for its all-ones result.
      negate_q <= want_remainder ? negative_a : ((negative_a ^ negative_b) && b != 0);
    end else if (phase_q == PREFIX) begin
      partial_remainder_q <= {24'b0, prefix_remainder};
      dividend_quotient_q <= {dividend_quotient_q[23:0], dividend_quotient_q[31:28], prefix_digit};
    end else if (phase_q > PREFIX && phase_q < DONE) begin
      partial_remainder_q <= next_remainder;
      dividend_quotient_q <= {dividend_quotient_q[27:0], quotient_digit};
    end
  end

  // INT_MIN / -1 naturally yields a positive magnitude of 2^31, whose
  // 32-bit representation is the required INT_MIN. Its remainder is zero.
  assign magnitude_result = remainder_q ? partial_remainder_q : dividend_quotient_q;
  assign result = negate_q ? -magnitude_result : magnitude_result;
`endif

endmodule
