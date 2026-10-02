// Shared RV32M divider: magnitude capture, eight-bit prefix initialization,
// then six edges of one fused radix-16 digit. Completion is always edge eight.
// The full-width recurrence reads only registered state and multiples.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        launch,
  input  logic        consume,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        result_valid,
  output logic [31:0] result
);
  logic [2:0] remaining_q;

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result_q;
  assign result = alt_result_q;
`else
  logic [31:0] quotient_q, remainder_q;
  logic [35:0] divisor_q, triple_divisor_q, five_divisor_q, seven_divisor_q;
  logic [35:0] nine_divisor_q, eleven_divisor_q, thirteen_divisor_q, fifteen_divisor_q;
  logic quotient_negative_q, remainder_negative_q, select_remainder_q;
  logic signed_op;
  logic [31:0] magnitude_a, magnitude_b;
  // Q holds the untouched dividend before initialization. Captured D feeds
  // only edge two; the recurrence's whole odd-multiple bank starts there.
  wire [31:0] magnitude_a_q = quotient_q;
  logic [31:0] magnitude_b_q;
  wire [35:0] captured_divisor = {4'b0, magnitude_b_q};
  logic [7:0] prefix_x;
  logic [3:0] nibble_q, nibble_r;
  logic [7:0] prefix_quotient, prefix_remainder;
  wire [7:0] prefix_divisor = magnitude_b_q[7:0];
  wire [3:0] nibble_quotient = (|prefix_divisor[7:4]) ? 4'b0 : nibble_q;
  wire [3:0] nibble_remainder = (|prefix_divisor[7:4])
                              ? magnitude_a_q[31:28] : nibble_r;
  wire [7:0] prefix_trial = {nibble_remainder, magnitude_a_q[27:24]};
  wire [11:0] prefix_d = {4'b0, prefix_divisor};
  wire [11:0] prefix_three = prefix_d + (prefix_d << 1);
  wire [11:0] prefix_five = prefix_d + (prefix_d << 2);
  wire [11:0] prefix_seven = sum_three_12(prefix_d, prefix_d << 1, prefix_d << 2);
  wire [11:0] prefix_multiple [1:15];
  wire [16:0] prefix_fit;
  // Adjacent-fit decoders are verification monitors only, never data gates.
  /* verilator lint_off UNUSEDSIGNAL */
  wire [15:0] prefix_select;
  /* verilator lint_on UNUSEDSIGNAL */
  wire [7:0] prefix_leaf_r [0:15], prefix_pair_r [0:7];
  wire [7:0] prefix_quad_r [0:3], prefix_oct_r [0:1];
  wire [3:0] prefix_leaf_digit [0:15], prefix_pair_digit [0:7];
  wire [3:0] prefix_quad_digit [0:3], prefix_oct_digit [0:1];
  wire [3:0] prefix_digit;
  wire [35:0] shifted = {remainder_q, quotient_q[31:28]};
  wire [35:0] multiple [1:15];
  wire [16:0] fit;
  /* verilator lint_off UNUSEDSIGNAL */
  wire [15:0] select_digit;
  /* verilator lint_on UNUSEDSIGNAL */
  wire [31:0] leaf_r [0:15], pair_r [0:7], quad_r [0:3], oct_r [0:1];
  wire [3:0] leaf_digit [0:15], pair_digit [0:7];
  wire [3:0] quad_digit [0:3], oct_digit [0:1];
  wire [3:0] digit;
  wire [31:0] quotient_next, remainder_next;
  // Only the underflow bit and bounded low 32 bits of a trial are used.
  /* verilator lint_off UNUSEDSIGNAL */
  wire [12:0] prefix_difference [1:15];
  wire [36:0] difference [1:15];
  /* verilator lint_on UNUSEDSIGNAL */

  // Three shifted terms are compressed before the sole carry-propagating
  // add. Every operation keeps the exact unsigned multiple width.
  function automatic [11:0] sum_three_12(
    input [11:0] x, input [11:0] y, input [11:0] z
  );
    sum_three_12 = (x ^ y ^ z) + (((x & y) | (x & z) | (y & z)) << 1);
  endfunction
  function automatic [35:0] sum_three_36(
    input [35:0] x, input [35:0] y, input [35:0] z
  );
    sum_three_36 = (x ^ y ^ z) + (((x & y) | (x & z) | (y & z)) << 1);
  endfunction

  always_comb begin
    signed_op = (op == ALU_DIV || op == ALU_REM);
    magnitude_a = (signed_op && a[31]) ? -a : a;
    magnitude_b = (signed_op && b[31]) ? -b : b;
  end

  // Offline enumeration of x={D[3:0],A[31:28]} gives Q=P/D,R=P%D
  // for D!=0 and Q=15,R=P for D=0. Deterministic cube merging retains
  // primes, selects essentials, then greedily covers most uncovered points,
  // fewest literals, ascending (value,don't-care mask). Explicit Boolean
  // equations prevent ROM/BSRAM inference; no variable-index lookup exists.
  assign prefix_x = {magnitude_b_q[3:0], magnitude_a_q[31:28]};
  // 21 prime-implicant product terms.
  assign nibble_r[0] =
      (~prefix_x[4] & prefix_x[0]) |
      (prefix_x[5] & ~prefix_x[3] & ~prefix_x[2] & ~prefix_x[1] & prefix_x[0]) |
      (~prefix_x[6] & prefix_x[5] & ~prefix_x[3] & prefix_x[2] & prefix_x[1] & prefix_x[0]) |
      (~prefix_x[7] & ~prefix_x[6] & prefix_x[5] & prefix_x[3] & prefix_x[2] & ~prefix_x[1] & prefix_x[0]) |
      (~prefix_x[7] & ~prefix_x[6] & prefix_x[5] & prefix_x[4] & ~prefix_x[3] & prefix_x[2] & ~prefix_x[1] & ~prefix_x[0]) |
      (~prefix_x[7] & prefix_x[5] & prefix_x[4] & prefix_x[3] & ~prefix_x[2] & prefix_x[1] & ~prefix_x[0]) |
      (prefix_x[6] & ~prefix_x[3] & ~prefix_x[2] & prefix_x[0]) |
      (prefix_x[6] & ~prefix_x[5] & ~prefix_x[2] & prefix_x[1] & prefix_x[0]) |
      (~prefix_x[7] & prefix_x[6] & ~prefix_x[5] & prefix_x[3] & prefix_x[2] & ~prefix_x[1] & prefix_x[0]) |
      (~prefix_x[7] & prefix_x[6] & ~prefix_x[5] & prefix_x[4] & ~prefix_x[3] & prefix_x[2] & prefix_x[1] & ~prefix_x[0]) |
      (~prefix_x[7] & prefix_x[6] & prefix_x[4] & prefix_x[3] & ~prefix_x[2] & ~prefix_x[1] & ~prefix_x[0]) |
      (prefix_x[6] & prefix_x[5] & ~prefix_x[3] & ~prefix_x[1] & prefix_x[0]) |
      (~prefix_x[7] & prefix_x[6] & prefix_x[5] & prefix_x[3] & prefix_x[2] & prefix_x[1] & prefix_x[0]) |
      (~prefix_x[7] & prefix_x[6] & prefix_x[5] & prefix_x[4] & prefix_x[3] & ~prefix_x[1] & ~prefix_x[0]) |
      (prefix_x[7] & ~prefix_x[3] & prefix_x[0]) |
      (prefix_x[7] & ~prefix_x[6] & ~prefix_x[5] & prefix_x[4] & prefix_x[3] & prefix_x[1] & ~prefix_x[0]) |
      (prefix_x[7] & ~prefix_x[6] & prefix_x[4] & prefix_x[3] & prefix_x[2] & ~prefix_x[0]) |
      (prefix_x[7] & ~prefix_x[5] & prefix_x[4] & prefix_x[3] & prefix_x[2] & prefix_x[1] & ~prefix_x[0]) |
      (prefix_x[7] & prefix_x[5] & ~prefix_x[2] & ~prefix_x[1] & prefix_x[0]) |
      (prefix_x[7] & prefix_x[6] & ~prefix_x[2] & prefix_x[0]) |
      (prefix_x[7] & prefix_x[6] & prefix_x[5] & ~prefix_x[1] & prefix_x[0]);
  // 22 prime-implicant product terms.
  assign nibble_r[1] =
      (~prefix_x[5] & ~prefix_x[4] & prefix_x[1]) |
      (prefix_x[5] & prefix_x[4] & ~prefix_x[3] & ~prefix_x[2] & prefix_x[1] & ~prefix_x[0]) |
      (~prefix_x[7] & ~prefix_x[6] & prefix_x[5] & prefix_x[4] & ~prefix_x[3] & prefix_x[2] & ~prefix_x[1] & prefix_x[0]) |
      (~prefix_x[7] & ~prefix_x[6] & prefix_x[5] & prefix_x[4] & prefix_x[3] & ~prefix_x[2] & ~prefix_x[1] & ~prefix_x[0]) |
      (~prefix_x[7] & ~prefix_x[6] & prefix_x[5] & prefix_x[4] & prefix_x[3] & ~prefix_x[2] & prefix_x[1] & prefix_x[0]) |
      (~prefix_x[6] & prefix_x[5] & prefix_x[4] & prefix_x[3] & prefix_x[2] & prefix_x[1] & ~prefix_x[0]) |
      (prefix_x[6] & ~prefix_x[3] & ~prefix_x[2] & prefix_x[1]) |
      (prefix_x[6] & ~prefix_x[5] & ~prefix_x[3] & prefix_x[1] & prefix_x[0]) |
      (~prefix_x[7] & prefix_x[6] & ~prefix_x[4] & prefix_x[3] & prefix_x[2] & prefix_x[1]) |
      (~prefix_x[7] & prefix_x[6] & ~prefix_x[5] & prefix_x[4] & prefix_x[3] & ~prefix_x[1] & ~prefix_x[0]) |
      (~prefix_x[7] & prefix_x[6] & prefix_x[4] & prefix_x[3] & prefix_x[2] & ~prefix_x[1] & prefix_x[0]) |
      (~prefix_x[7] & prefix_x[6] & prefix_x[5] & ~prefix_x[4] & prefix_x[3] & ~prefix_x[2] & ~prefix_x[1]) |
      (~prefix_x[7] & prefix_x[6] & prefix_x[5] & prefix_x[3] & ~prefix_x[2] & ~prefix_x[1] & prefix_x[0]) |
      (prefix_x[6] & prefix_x[5] & prefix_x[4] & ~prefix_x[3] & prefix_x[1] & ~prefix_x[0]) |
      (prefix_x[6] & prefix_x[5] & prefix_x[4] & ~prefix_x[2] & prefix_x[1] & ~prefix_x[0]) |
      (prefix_x[7] & ~prefix_x[3] & prefix_x[1]) |
      (prefix_x[7] & ~prefix_x[5] & prefix_x[1] & prefix_x[0]) |
      (prefix_x[7] & ~prefix_x[6] & ~prefix_x[5] & prefix_x[4] & prefix_x[3] & prefix_x[2] & ~prefix_x[1] & ~prefix_x[0]) |
      (prefix_x[7] & ~prefix_x[6] & prefix_x[5] & ~prefix_x[4] & prefix_x[3] & prefix_x[2] & ~prefix_x[1]) |
      (prefix_x[7] & ~prefix_x[6] & prefix_x[5] & prefix_x[3] & prefix_x[2] & ~prefix_x[1] & prefix_x[0]) |
      (prefix_x[7] & prefix_x[5] & prefix_x[4] & prefix_x[1] & ~prefix_x[0]) |
      (prefix_x[7] & prefix_x[6] & ~prefix_x[2] & prefix_x[1]);
  // 17 prime-implicant product terms.
  assign nibble_r[2] =
      (~prefix_x[6] & ~prefix_x[5] & ~prefix_x[4] & prefix_x[2]) |
      (prefix_x[6] & prefix_x[4] & ~prefix_x[3] & prefix_x[2] & ~prefix_x[1] & ~prefix_x[0]) |
      (~prefix_x[7] & prefix_x[6] & ~prefix_x[5] & prefix_x[4] & prefix_x[3] & ~prefix_x[2] & ~prefix_x[1] & prefix_x[0]) |
      (~prefix_x[7] & prefix_x[6] & ~prefix_x[5] & prefix_x[4] & prefix_x[3] & prefix_x[2] & prefix_x[1] & ~prefix_x[0]) |
      (prefix_x[6] & prefix_x[5] & ~prefix_x[3] & prefix_x[2] & ~prefix_x[1]) |
      (~prefix_x[7] & prefix_x[6] & prefix_x[5] & ~prefix_x[4] & prefix_x[3] & ~prefix_x[2] & prefix_x[1]) |
      (~prefix_x[7] & prefix_x[6] & prefix_x[5] & prefix_x[3] & ~prefix_x[2] & prefix_x[1] & prefix_x[0]) |
      (prefix_x[6] & prefix_x[5] & prefix_x[4] & ~prefix_x[3] & prefix_x[2] & ~prefix_x[0]) |
      (prefix_x[6] & prefix_x[5] & prefix_x[4] & prefix_x[2] & ~prefix_x[1]) |
      (prefix_x[7] & ~prefix_x[3] & prefix_x[2]) |
      (prefix_x[7] & ~prefix_x[6] & ~prefix_x[5] & prefix_x[2] & prefix_x[0]) |
      (prefix_x[7] & ~prefix_x[6] & ~prefix_x[5] & prefix_x[2] & prefix_x[1]) |
      (prefix_x[7] & ~prefix_x[6] & ~prefix_x[4] & prefix_x[2] & prefix_x[1]) |
      (prefix_x[7] & ~prefix_x[6] & prefix_x[2] & prefix_x[1] & prefix_x[0]) |
      (prefix_x[7] & prefix_x[6] & prefix_x[4] & prefix_x[2] & ~prefix_x[1] & ~prefix_x[0]) |
      (prefix_x[7] & prefix_x[6] & prefix_x[5] & prefix_x[2] & ~prefix_x[1]) |
      (prefix_x[7] & prefix_x[6] & prefix_x[5] & prefix_x[4] & prefix_x[2] & ~prefix_x[0]);
  // 8 prime-implicant product terms.
  assign nibble_r[3] =
      (~prefix_x[7] & ~prefix_x[6] & ~prefix_x[5] & ~prefix_x[4] & prefix_x[3]) |
      (prefix_x[7] & prefix_x[4] & prefix_x[3] & ~prefix_x[2] & ~prefix_x[1] & ~prefix_x[0]) |
      (prefix_x[7] & prefix_x[5] & prefix_x[3] & ~prefix_x[2] & ~prefix_x[1]) |
      (prefix_x[7] & prefix_x[5] & prefix_x[4] & prefix_x[3] & ~prefix_x[2] & ~prefix_x[0]) |
      (prefix_x[7] & prefix_x[6] & prefix_x[3] & ~prefix_x[2]) |
      (prefix_x[7] & prefix_x[6] & prefix_x[4] & prefix_x[3] & ~prefix_x[1] & ~prefix_x[0]) |
      (prefix_x[7] & prefix_x[6] & prefix_x[5] & prefix_x[3] & ~prefix_x[1]) |
      (prefix_x[7] & prefix_x[6] & prefix_x[5] & prefix_x[4] & prefix_x[3] & ~prefix_x[0]);
  // 27 prime-implicant product terms.
  assign nibble_q[0] =
      (~prefix_x[7] & ~prefix_x[6] & ~prefix_x[5] & ~prefix_x[4]) |
      (~prefix_x[7] & ~prefix_x[6] & ~prefix_x[5] & prefix_x[0]) |
      (~prefix_x[7] & ~prefix_x[6] & ~prefix_x[4] & prefix_x[1]) |
      (~prefix_x[7] & ~prefix_x[6] & ~prefix_x[2] & prefix_x[1] & prefix_x[0]) |
      (~prefix_x[7] & ~prefix_x[5] & ~prefix_x[4] & prefix_x[2]) |
      (~prefix_x[7] & ~prefix_x[5] & ~prefix_x[3] & prefix_x[2] & prefix_x[0]) |
      (~prefix_x[7] & ~prefix_x[4] & ~prefix_x[3] & prefix_x[2] & prefix_x[1]) |
      (~prefix_x[7] & ~prefix_x[5] & prefix_x[2] & prefix_x[1] & prefix_x[0]) |
      (~prefix_x[6] & ~prefix_x[5] & ~prefix_x[4] & prefix_x[3]) |
      (~prefix_x[6] & ~prefix_x[5] & prefix_x[3] & prefix_x[0]) |
      (~prefix_x[6] & ~prefix_x[4] & prefix_x[3] & prefix_x[1]) |
      (~prefix_x[6] & prefix_x[3] & prefix_x[1] & prefix_x[0]) |
      (~prefix_x[5] & ~prefix_x[4] & prefix_x[3] & prefix_x[2]) |
      (~prefix_x[7] & ~prefix_x[6] & prefix_x[4] & prefix_x[3] & ~prefix_x[2] & prefix_x[0]) |
      (~prefix_x[7] & prefix_x[5] & prefix_x[3] & ~prefix_x[2] & prefix_x[1]) |
      (~prefix_x[7] & ~prefix_x[6] & prefix_x[5] & prefix_x[4] & ~prefix_x[3] & prefix_x[2] & ~prefix_x[1]) |
      (~prefix_x[7] & prefix_x[6] & ~prefix_x[5] & ~prefix_x[3] & prefix_x[2] & prefix_x[1]) |
      (~prefix_x[7] & prefix_x[6] & ~prefix_x[3] & prefix_x[2] & prefix_x[1] & prefix_x[0]) |
      (~prefix_x[7] & prefix_x[6] & prefix_x[4] & prefix_x[3] & ~prefix_x[2] & ~prefix_x[1]) |
      (~prefix_x[7] & prefix_x[6] & prefix_x[5] & prefix_x[3] & ~prefix_x[2]) |
      (~prefix_x[7] & prefix_x[6] & prefix_x[5] & prefix_x[4] & prefix_x[3] & ~prefix_x[1]) |
      (prefix_x[7] & ~prefix_x[6] & ~prefix_x[5] & prefix_x[3] & prefix_x[1]) |
      (prefix_x[7] & ~prefix_x[6] & prefix_x[3] & prefix_x[2]) |
      (prefix_x[7] & ~prefix_x[5] & prefix_x[3] & prefix_x[2] & prefix_x[0]) |
      (prefix_x[7] & ~prefix_x[5] & prefix_x[3] & prefix_x[2] & prefix_x[1]) |
      (prefix_x[7] & ~prefix_x[4] & prefix_x[3] & prefix_x[2] & prefix_x[1]) |
      (prefix_x[7] & prefix_x[3] & prefix_x[2] & prefix_x[1] & prefix_x[0]);
  // 10 prime-implicant product terms.
  assign nibble_q[1] =
      (~prefix_x[7] & ~prefix_x[6] & ~prefix_x[5] & ~prefix_x[4]) |
      (~prefix_x[7] & ~prefix_x[6] & ~prefix_x[5] & prefix_x[1]) |
      (~prefix_x[7] & ~prefix_x[6] & ~prefix_x[4] & prefix_x[2]) |
      (~prefix_x[7] & ~prefix_x[6] & ~prefix_x[3] & prefix_x[2] & prefix_x[1]) |
      (~prefix_x[7] & ~prefix_x[5] & ~prefix_x[4] & prefix_x[3]) |
      (~prefix_x[7] & ~prefix_x[5] & prefix_x[3] & prefix_x[1]) |
      (~prefix_x[7] & ~prefix_x[4] & prefix_x[3] & prefix_x[2]) |
      (~prefix_x[7] & ~prefix_x[6] & prefix_x[5] & prefix_x[4] & prefix_x[3] & ~prefix_x[2]) |
      (~prefix_x[7] & prefix_x[6] & ~prefix_x[5] & prefix_x[3] & prefix_x[2]) |
      (~prefix_x[7] & prefix_x[6] & prefix_x[3] & prefix_x[2] & prefix_x[1]);
  // 4 prime-implicant product terms.
  assign nibble_q[2] =
      (~prefix_x[7] & ~prefix_x[6] & ~prefix_x[5] & ~prefix_x[4]) |
      (~prefix_x[7] & ~prefix_x[6] & ~prefix_x[5] & prefix_x[2]) |
      (~prefix_x[7] & ~prefix_x[6] & ~prefix_x[4] & prefix_x[3]) |
      (~prefix_x[7] & ~prefix_x[6] & prefix_x[3] & prefix_x[2]);
  // 2 prime-implicant product terms.
  assign nibble_q[3] =
      (~prefix_x[7] & ~prefix_x[6] & ~prefix_x[5] & ~prefix_x[4]) |
      (~prefix_x[7] & ~prefix_x[6] & ~prefix_x[5] & prefix_x[3]);

  // Narrow odd multiples are independent of both nibble outputs and the
  // wide-divisor guard. Twelve bits keep 15*255 exact; bit 12 is borrow.
  assign prefix_multiple[1] = prefix_d;
  assign prefix_multiple[3] = prefix_three;
  assign prefix_multiple[5] = prefix_five;
  assign prefix_multiple[7] = prefix_seven;
  assign prefix_multiple[9] = prefix_d + (prefix_d << 3);
  assign prefix_multiple[11] = sum_three_12(prefix_d, prefix_d << 1, prefix_d << 3);
  assign prefix_multiple[13] = sum_three_12(prefix_d, prefix_d << 2, prefix_d << 3);
  assign prefix_multiple[15] = (prefix_d << 4) - prefix_d;
  assign prefix_multiple[2] = prefix_d << 1;
  assign prefix_multiple[4] = prefix_d << 2;
  assign prefix_multiple[6] = prefix_three << 1;
  assign prefix_multiple[8] = prefix_d << 3;
  assign prefix_multiple[10] = prefix_five << 1;
  assign prefix_multiple[12] = prefix_three << 2;
  assign prefix_multiple[14] = prefix_seven << 1;
  assign prefix_fit[0] = 1'b1;
  assign prefix_fit[16] = 1'b0;
  for (genvar k = 1; k < 16; k++) begin : prefix_trials
    assign prefix_difference[k] = {5'b0, prefix_trial} - {1'b0, prefix_multiple[k]};
    assign prefix_fit[k] = !prefix_difference[k][12];
    assign prefix_leaf_r[k] = prefix_difference[k][7:0];
  end
  assign prefix_leaf_r[0] = prefix_trial;
  for (genvar k = 0; k < 16; k++) begin : prefix_selectors
    assign prefix_select[k] = prefix_fit[k] && !prefix_fit[k+1];
    assign prefix_leaf_digit[k] = 4'(k);
  end
  // Ordered exact trials form a thermometer code. Fixed-index binary
  // partitions choose the largest fitting leaf in four two-way mux levels.
  // Remainder and digit always follow the identical partition selectors.
  for (genvar k = 0; k < 8; k++) begin : prefix_pairs
    assign prefix_pair_r[k] = prefix_fit[2*k+1] ? prefix_leaf_r[2*k+1] : prefix_leaf_r[2*k];
    assign prefix_pair_digit[k] = prefix_fit[2*k+1] ? prefix_leaf_digit[2*k+1] : prefix_leaf_digit[2*k];
  end
  for (genvar k = 0; k < 4; k++) begin : prefix_quads
    assign prefix_quad_r[k] = prefix_fit[4*k+2] ? prefix_pair_r[2*k+1] : prefix_pair_r[2*k];
    assign prefix_quad_digit[k] = prefix_fit[4*k+2] ? prefix_pair_digit[2*k+1] : prefix_pair_digit[2*k];
  end
  for (genvar k = 0; k < 2; k++) begin : prefix_octs
    assign prefix_oct_r[k] = prefix_fit[8*k+4] ? prefix_quad_r[2*k+1] : prefix_quad_r[2*k];
    assign prefix_oct_digit[k] = prefix_fit[8*k+4] ? prefix_quad_digit[2*k+1] : prefix_quad_digit[2*k];
  end
  assign prefix_digit = prefix_fit[8] ? prefix_oct_digit[1] : prefix_oct_digit[0];
  // A divisor >=256 exceeds the whole byte. Qualify only these final
  // outputs, so its high bits cannot enter either narrow digit decision.
  assign prefix_quotient = (|magnitude_b_q[31:8]) ? 8'b0
                        : {nibble_quotient, prefix_digit};
  assign prefix_remainder = (|magnitude_b_q[31:8]) ? magnitude_a_q[31:24]
                         : (prefix_fit[8] ? prefix_oct_r[1] : prefix_oct_r[0]);

  // Every recurrence multiple is registered or a constant shift of a
  // registered odd multiple. No multiple-generation adder is in this cone.
  assign multiple[1] = divisor_q;
  assign multiple[3] = triple_divisor_q;
  assign multiple[5] = five_divisor_q;
  assign multiple[7] = seven_divisor_q;
  assign multiple[9] = nine_divisor_q;
  assign multiple[11] = eleven_divisor_q;
  assign multiple[13] = thirteen_divisor_q;
  assign multiple[15] = fifteen_divisor_q;
  assign multiple[2] = divisor_q << 1;
  assign multiple[4] = divisor_q << 2;
  assign multiple[6] = triple_divisor_q << 1;
  assign multiple[8] = divisor_q << 3;
  assign multiple[10] = five_divisor_q << 1;
  assign multiple[12] = triple_divisor_q << 2;
  assign multiple[14] = seven_divisor_q << 1;
  assign fit[0] = 1'b1;
  assign fit[16] = 1'b0;
  for (genvar k = 1; k < 16; k++) begin : trials
    assign difference[k] = {1'b0, shifted} - {1'b0, multiple[k]};
    assign fit[k] = !difference[k][36];
    assign leaf_r[k] = difference[k][31:0];
  end
  assign leaf_r[0] = shifted[31:0];
  // Exact ordered multiples make fits monotonic. For D=0 every trial
  // fits, so digit 15 wins and the incoming prefix is retained.
  for (genvar k = 0; k < 16; k++) begin : selectors
    assign select_digit[k] = fit[k] && !fit[k+1];
    assign leaf_digit[k] = 4'(k);
  end
  for (genvar k = 0; k < 8; k++) begin : pairs
    assign pair_r[k] = fit[2*k+1] ? leaf_r[2*k+1] : leaf_r[2*k];
    assign pair_digit[k] = fit[2*k+1] ? leaf_digit[2*k+1] : leaf_digit[2*k];
  end
  for (genvar k = 0; k < 4; k++) begin : quads
    assign quad_r[k] = fit[4*k+2] ? pair_r[2*k+1] : pair_r[2*k];
    assign quad_digit[k] = fit[4*k+2] ? pair_digit[2*k+1] : pair_digit[2*k];
  end
  for (genvar k = 0; k < 2; k++) begin : octs
    assign oct_r[k] = fit[8*k+4] ? quad_r[2*k+1] : quad_r[2*k];
    assign oct_digit[k] = fit[8*k+4] ? quad_digit[2*k+1] : quad_digit[2*k];
  end
  assign remainder_next = fit[8] ? oct_r[1] : oct_r[0];
  assign digit = fit[8] ? oct_digit[1] : oct_digit[0];
  assign quotient_next = {quotient_q[27:0], digit};

  always_comb begin
    result = select_remainder_q
           ? (remainder_negative_q ? -remainder_q : remainder_q)
           : (quotient_negative_q ? -quotient_q : quotient_q);
  end
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      busy <= 1'b0;
      result_valid <= 1'b0;
      remaining_q <= 3'b0;
`ifdef RISCV_FORMAL_ALTOPS
      alt_result_q <= 32'b0;
`else
      quotient_q <= 32'b0;
      remainder_q <= 32'b0;
      magnitude_b_q <= 32'b0;
      divisor_q <= 36'b0;
      triple_divisor_q <= 36'b0;
      five_divisor_q <= 36'b0;
      seven_divisor_q <= 36'b0;
      nine_divisor_q <= 36'b0;
      eleven_divisor_q <= 36'b0;
      thirteen_divisor_q <= 36'b0;
      fifteen_divisor_q <= 36'b0;
      quotient_negative_q <= 1'b0;
      remainder_negative_q <= 1'b0;
      select_remainder_q <= 1'b0;
`endif
    end else begin
      if (consume) result_valid <= 1'b0;
      if (launch && !busy && (!result_valid || consume) &&
          (op == ALU_DIV || op == ALU_DIVU || op == ALU_REM || op == ALU_REMU)) begin
        busy <= 1'b1;
        result_valid <= 1'b0;
        remaining_q <= 3'd7;
`ifdef RISCV_FORMAL_ALTOPS
        case (op)
          ALU_DIV:  alt_result_q <= (a - b) ^ 32'h7f8529ec;
          ALU_DIVU: alt_result_q <= (a - b) ^ 32'h10e8fd70;
          ALU_REM:  alt_result_q <= (a - b) ^ 32'h8da68fa5;
          ALU_REMU: alt_result_q <= (a - b) ^ 32'h3138d0e1;
          default:  alt_result_q <= 32'b0;
        endcase
`else
        // Edge one captures magnitudes and metadata only: zero bits consumed.
        quotient_q <= magnitude_a;
        remainder_q <= 32'b0;
        magnitude_b_q <= magnitude_b;
        // A zero divisor generates an all-ones quotient naturally. Do
        // not negate that quotient, even for a negative dividend.
        quotient_negative_q <= signed_op && (a[31] ^ b[31]) && (b != 0);
        remainder_negative_q <= signed_op && a[31];
        select_remainder_q <= (op == ALU_REM || op == ALU_REMU);
`endif
      end else if (busy) begin
`ifndef RISCV_FORMAL_ALTOPS
        if (remaining_q == 3'd7) begin
          // Edge two generates every full-width odd multiple directly
          // from captured D, in parallel with the complete byte prefix.
          quotient_q <= {magnitude_a_q[23:0], prefix_quotient};
          remainder_q <= {24'b0, prefix_remainder};
          divisor_q <= captured_divisor;
          triple_divisor_q <= captured_divisor + (captured_divisor << 1);
          five_divisor_q <= captured_divisor + (captured_divisor << 2);
          seven_divisor_q <= sum_three_36(captured_divisor, captured_divisor << 1, captured_divisor << 2);
          nine_divisor_q <= captured_divisor + (captured_divisor << 3);
          eleven_divisor_q <= sum_three_36(captured_divisor, captured_divisor << 1, captured_divisor << 3);
          thirteen_divisor_q <= sum_three_36(captured_divisor, captured_divisor << 2, captured_divisor << 3);
          fifteen_divisor_q <= (captured_divisor << 4) - captured_divisor;
        end else begin
          quotient_q <= quotient_next;
          remainder_q <= remainder_next;
        end
`endif
        remaining_q <= remaining_q - 3'd1;
        if (remaining_q == 3'd1) begin
          busy <= 1'b0;
          result_valid <= 1'b1;
        end
      end
    end
  end
endmodule
