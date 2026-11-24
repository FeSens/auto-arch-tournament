// Shared blocking RV32M divider. Launch captures the operands, then
// initialization consumes a prefix of the dividend. Seven work edges
// follow. EX can hand off on the last work edge, which registers the
// final state used for the MEM result.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        launch,
  input  logic        accept,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        idle,
  output logic        handoff_ready,
  output logic [31:0] result
);

  // 0 = idle, 9 = initialize, 8..2 = seven work cycles, 1 = result pending.
  logic [3:0] phase_q;
  logic starting, initializing, counting_down;
  logic [31:0] a_q, b_q;

  assign idle          = phase_q == 4'd0;
  assign handoff_ready = phase_q == 4'd2 || phase_q == 4'd1;
  assign starting      = idle && launch;
  assign initializing  = phase_q == 4'd9;
  assign counting_down = |phase_q[3:1];

  always_ff @(posedge clock) begin
    if (reset)                       phase_q <= 4'd0;
    else if (starting)               phase_q <= 4'd9;
    else if (handoff_ready && accept) phase_q <= 4'd0;
    else if (counting_down)           phase_q <= phase_q - 4'd1;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      a_q <= '0;
      b_q <= '0;
    end else if (starting) begin
      a_q <= a;
      b_q <= b;
    end
  end

`ifdef RISCV_FORMAL_ALTOPS
  logic [4:0] op_q;
  logic [31:0] alt_mask;

  always_comb begin
    case (op_q)
      ALU_DIV:  alt_mask = 32'h7f8529ec;
      ALU_DIVU: alt_mask = 32'h10e8fd70;
      ALU_REM:  alt_mask = 32'h8da68fa5;
      ALU_REMU: alt_mask = 32'h3138d0e1;
      default:  alt_mask = '0;
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      op_q   <= '0;
      result <= '0;
    end else if (starting) begin
      op_q <= op;
    end else if (initializing) begin
      result <= (a_q - b_q) ^ alt_mask;
    end
  end
`else
  logic signed_op, a_negative_q, b_negative_q;
  logic [31:0] a_magnitude, b_magnitude;
  logic [34:0] extended_divisor;
  logic divisor_zero, narrow_divisor, nibble_divisor;
  logic narrow_q, want_remainder_q, negate_q;
  logic [31:0] divisor_q, remainder_q, quotient_q;
  logic [34:0] three_divisor_q, five_divisor_q, seven_divisor_q;
  logic [14:0] nine_divisor_q, eleven_divisor_q, thirteen_divisor_q, fifteen_divisor_q;
  logic [14:0] narrow_divisor_value;
  logic [31:0] magnitude;

  assign signed_op = op == ALU_DIV || op == ALU_REM;

  // Each byte of the negated divisor receives a carry only when every
  // lower raw bit is zero. Compute those carries in parallel.
  assign b_magnitude[7:0]   = b_negative_q ? -b_q[7:0] : b_q[7:0];
  assign b_magnitude[15:8]  = b_negative_q ? ~b_q[15:8]  + {7'b0, !(|b_q[7:0])}  : b_q[15:8];
  assign b_magnitude[23:16] = b_negative_q ? ~b_q[23:16] + {7'b0, !(|b_q[15:0])} : b_q[23:16];
  assign b_magnitude[31:24] = b_negative_q ? ~b_q[31:24] + {7'b0, !(|b_q[23:0])} : b_q[31:24];

  // Negation flips each dividend bit above its lowest set bit. Compute
  // the nibble used by the prefix lookup directly from the raw dividend.
  assign a_magnitude[0] = a_q[0];
  for (genvar i = 1; i < 32; i++) begin : gen_dividend_magnitude
    assign a_magnitude[i] = a_q[i] ^ (a_negative_q && |a_q[i-1:0]);
  end

  assign extended_divisor = {3'b0, b_magnitude};
  assign divisor_zero = !(|b_q);
  // Classify from the raw divisor in parallel with magnitude formation.
  // The negative boundary itself has a zero low field (-2048 or -16).
  assign narrow_divisor = b_negative_q ? (&b_q[31:11] && |b_q[10:0])
                                       : (!(|b_q[31:11]) && |b_q[10:0]);
  assign nibble_divisor = b_negative_q ? (&b_q[31:4] && |b_q[3:0])
                                       : (!(|b_q[31:4]) && |b_q[3:0]);

  // Build constant truth tables for each output bit of nibble / D and
  // nibble % D. At runtime the nibble indexes each decoded divisor row.
  function automatic [15:0] prefix_lut (
    input int divisor,
    input int bit_index,
    input bit use_remainder
  );
    for (int nibble = 0; nibble < 16; nibble++) begin
      if (use_remainder)
        prefix_lut[nibble] = 1'((nibble % divisor) >> bit_index);
      else
        prefix_lut[nibble] = 1'((nibble / divisor) >> bit_index);
    end
  endfunction

  logic [14:0] prefix_row;
  logic [3:0] prefix_quotient, prefix_remainder;

  for (genvar divisor = 1; divisor < 16; divisor++) begin : gen_prefix_row
    assign prefix_row[divisor-1] = b_negative_q ? b_q[3:0] == 4'(-divisor)
                                               : b_q[3:0] == 4'(divisor);
  end

  for (genvar i = 0; i < 4; i++) begin : gen_prefix_bit
    logic [14:0] quotient_bits, remainder_bits;
    for (genvar divisor = 1; divisor < 16; divisor++) begin : gen_lut
      localparam logic [15:0] QUOTIENT = prefix_lut(divisor, i, 1'b0);
      localparam logic [15:0] REMAINDER = prefix_lut(divisor, i, 1'b1);
      assign quotient_bits[divisor-1] = prefix_row[divisor-1] && QUOTIENT[a_magnitude[31:28]];
      assign remainder_bits[divisor-1] = prefix_row[divisor-1] && REMAINDER[a_magnitude[31:28]];
    end
    assign prefix_quotient[i] = |quotient_bits;
    assign prefix_remainder[i] = |remainder_bits;
  end

  logic [34:0] multiples [1:7];
  logic [31:0] partial_dividend, wide_remainder;
  logic [31:0] trial_remainder [0:7];
  logic [8:0] borrow;
  logic [7:0] use_digit;
  logic [2:0] wide_digit;

  assign multiples[1] = {3'b0, divisor_q};
  assign multiples[2] = {2'b0, divisor_q, 1'b0};
  assign multiples[3] = three_divisor_q;
  assign multiples[4] = {1'b0, divisor_q, 2'b0};
  assign multiples[5] = five_divisor_q;
  assign multiples[6] = three_divisor_q << 1;
  assign multiples[7] = seven_divisor_q;

  // With D below 2048, appending four bits to a reduced remainder fits
  // in 15 bits. Compare the full radix-16 digit in parallel.
  logic [14:0] narrow_dividend, narrow_multiples [1:15];
  logic [10:0] narrow_trials [0:15];
  logic [16:0] narrow_borrow;
  logic [15:0] narrow_use;
  logic [3:0] narrow_digit;
  logic [10:0] narrow_remainder;

  assign narrow_divisor_value = {4'b0, b_magnitude[10:0]};
  assign narrow_dividend = {remainder_q[10:0], quotient_q[31:28]};
  for (genvar digit = 1; digit <= 7; digit++) begin : gen_shared_multiple
    assign narrow_multiples[digit] = multiples[digit][14:0];
  end
  assign narrow_multiples[8]  = narrow_multiples[4] << 1;
  assign narrow_multiples[9]  = nine_divisor_q;
  assign narrow_multiples[10] = narrow_multiples[5] << 1;
  assign narrow_multiples[11] = eleven_divisor_q;
  assign narrow_multiples[12] = narrow_multiples[6] << 1;
  assign narrow_multiples[13] = thirteen_divisor_q;
  assign narrow_multiples[14] = narrow_multiples[7] << 1;
  assign narrow_multiples[15] = fifteen_divisor_q;

  assign narrow_trials[0] = narrow_dividend[10:0];
  assign narrow_borrow[0] = 1'b0;
  assign narrow_borrow[16] = 1'b1;
  for (genvar digit = 1; digit <= 15; digit++) begin : gen_narrow_trial
    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] difference;
    /* verilator lint_on UNUSEDSIGNAL */
    assign difference = {1'b0, narrow_dividend} - {1'b0, narrow_multiples[digit]};
    assign narrow_trials[digit] = difference[10:0];
    assign narrow_borrow[digit] = difference[15];
  end
  for (genvar digit = 0; digit <= 15; digit++) begin : gen_narrow_digit
    assign narrow_use[digit] = !narrow_borrow[digit] && narrow_borrow[digit+1];
  end
  assign narrow_digit = {|(narrow_use & 16'hff00), |(narrow_use & 16'hf0f0),
                         |(narrow_use & 16'hcccc), |(narrow_use & 16'haaaa)};
  always_comb begin
    narrow_remainder = '0;
    for (int digit = 0; digit <= 15; digit++)
      narrow_remainder |= {11{narrow_use[digit]}} & narrow_trials[digit];
  end

  // The partial dividend is bounded by the dividend prefix consumed so
  // far, even for D=0. A multiple wider than 32 bits cannot fit.
  assign partial_dividend = {remainder_q[28:0], quotient_q[31:29]};
  assign trial_remainder[0] = partial_dividend;
  assign borrow[0] = 1'b0;
  assign borrow[8] = 1'b1;
  for (genvar digit = 1; digit <= 7; digit++) begin : gen_trial
    logic [32:0] difference;
    assign difference = {1'b0, partial_dividend} - {1'b0, multiples[digit][31:0]};
    assign trial_remainder[digit] = difference[31:0];
    assign borrow[digit] = difference[32] || |multiples[digit][34:32];
  end

  // Monotonic borrow flags select the largest fitting multiple. For D=0
  // every trial fits, so digit 7 leaves the partial dividend unchanged.
  for (genvar digit = 0; digit <= 7; digit++) begin : gen_digit
    assign use_digit[digit] = !borrow[digit] && borrow[digit+1];
  end
  assign wide_digit = {|(use_digit & 8'hf0), |(use_digit & 8'hcc), |(use_digit & 8'haa)};
  assign wide_remainder = ({32{use_digit[0]}} & trial_remainder[0])
                        | ({32{use_digit[1]}} & trial_remainder[1])
                        | ({32{use_digit[2]}} & trial_remainder[2])
                        | ({32{use_digit[3]}} & trial_remainder[3])
                        | ({32{use_digit[4]}} & trial_remainder[4])
                        | ({32{use_digit[5]}} & trial_remainder[5])
                        | ({32{use_digit[6]}} & trial_remainder[6])
                        | ({32{use_digit[7]}} & trial_remainder[7]);

  always_ff @(posedge clock) begin
    if (reset) begin
      divisor_q         <= '0;
      three_divisor_q   <= '0;
      five_divisor_q    <= '0;
      seven_divisor_q   <= '0;
      nine_divisor_q    <= '0;
      eleven_divisor_q  <= '0;
      thirteen_divisor_q <= '0;
      fifteen_divisor_q <= '0;
      remainder_q       <= '0;
      quotient_q        <= '0;
      a_negative_q      <= 1'b0;
      b_negative_q      <= 1'b0;
      narrow_q          <= 1'b0;
      want_remainder_q  <= 1'b0;
      negate_q          <= 1'b0;
    end else if (starting) begin
      a_negative_q      <= signed_op && a[31];
      b_negative_q      <= signed_op && b[31];
      want_remainder_q  <= op == ALU_REM || op == ALU_REMU;
    end else if (initializing) begin
      divisor_q         <= b_magnitude;
      three_divisor_q   <= (extended_divisor << 1) + extended_divisor;
      five_divisor_q    <= (extended_divisor << 2) + extended_divisor;
      seven_divisor_q   <= (extended_divisor << 3) - extended_divisor;
      nine_divisor_q    <= (narrow_divisor_value << 3) + narrow_divisor_value;
      eleven_divisor_q  <= (narrow_divisor_value << 3) +
                           (narrow_divisor_value << 1) + narrow_divisor_value;
      thirteen_divisor_q <= (narrow_divisor_value << 4) -
                            (narrow_divisor_value << 1) - narrow_divisor_value;
      fifteen_divisor_q <= (narrow_divisor_value << 4) - narrow_divisor_value;
      narrow_q          <= narrow_divisor;
      negate_q          <= want_remainder_q ? a_negative_q
                                            : (a_negative_q ^ b_negative_q) && !divisor_zero;
      if (narrow_divisor) begin
        remainder_q <= {28'b0, nibble_divisor ? prefix_remainder : a_magnitude[31:28]};
        quotient_q  <= {a_magnitude[27:0], nibble_divisor ? prefix_quotient : 4'b0};
      end else begin
        // For D >= 2048 the leading 11 bits are already reduced.
        // D=0 seeds ones for the consumed quotient bits.
        remainder_q <= {21'b0, a_magnitude[31:21]};
        quotient_q  <= {a_magnitude[20:0], {11{divisor_zero}}};
      end
    end else if (counting_down) begin
      if (narrow_q) begin
        remainder_q <= {21'b0, narrow_remainder};
        quotient_q  <= {quotient_q[27:0], narrow_digit};
      end else begin
        remainder_q <= wide_remainder;
        quotient_q  <= {quotient_q[28:0], wide_digit};
      end
    end
  end

  // MEM selects and sign-corrects the registered final state.
  // Keeping 32 result bits also handles INT_MIN / -1 and INT_MIN % -1.
  assign magnitude = want_remainder_q ? remainder_q : quotient_q;
  assign result = negate_q ? -magnitude : magnitude;
`endif

endmodule
