// Registered RV32M divider. Launch consumes the first magnitude nibble;
// seven busy clocks consume the second nibble and six radix-16 digits.
// Group zero overlaps narrow arithmetic with registered divisor multiples.
// Sign correction follows the final magnitude register and holds until accept.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        result_valid,
  output logic [31:0] result,
  input  logic        result_accept
);
  logic [2:0] group_q;
`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result_q, launch_result;
  always_comb begin
    case (op)
      ALU_DIV:  launch_result = (a - b) ^ 32'h7f8529ec;
      ALU_DIVU: launch_result = (a - b) ^ 32'h10e8fd70;
      ALU_REM:  launch_result = (a - b) ^ 32'h8da68fa5;
      ALU_REMU: launch_result = (a - b) ^ 32'h3138d0e1;
      default:  launch_result = 32'b0;
    endcase
  end
`else
  logic [31:0] quotient_q, remainder_q, divisor_q, result_magnitude_q;
  logic [33:0] divisor_3x_q;
  logic quotient_negative_q, remainder_negative_q, select_remainder_q;
  // Retain the captured raw sign for state/handshake verification.
  /* verilator lint_off UNUSEDSIGNAL */
  logic divisor_negative_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic signed_op, negative_a, negative_b, divisor_ge16;
  // The top nibble uses the independent narrow normalization above.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] initial_a;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] initial_b;
  logic [3:0] top_a, low_b, launch_digit, launch_residual;
  logic [7:0] launch_lookup;
  logic [33:0] launch_v, launch_twice_v, launch_correction;
  logic [33:0] launch_sum, launch_carry, launch_3x;

  assign signed_op = (op == ALU_DIV || op == ALU_REM);
  assign negative_a = signed_op && a[31];
  assign negative_b = signed_op && b[31];
  assign initial_a = negative_a ? (32'b0 - a) : a;
  assign initial_b = negative_b ? (32'b0 - b) : b;
  // Compute the lookup index directly, in parallel with full normalization.
  assign top_a = negative_a ? (~a[31:28] + {3'b0, a[27:0] == 28'b0}) : a[31:28];
  assign low_b = negative_b ? (4'b0 - b[3:0]) : b[3:0];
  assign divisor_ge16 = negative_b ? (!(&b[31:4]) || b[3:0] == 4'b0)
                                  : (|b[31:4]);

  // Literal {P % D, P / D} ROM for P,D in 0..15. D=0 returns {P,15}.
  // Generated at implementation time; no arithmetic division or file load.
  localparam logic [2047:0] FIRST_DIGIT_TABLE = {
    128'h01112131415161711232033305170fff,
    128'he0011121314151610222422324070eef,
    128'hd0d00111213141516112321314160ddf,
    128'hc0c0c001112131415102220304060ccf,
    128'hb0b0b0b0011121314151123223150bbf,
    128'ha0a0a0a0a00111213141022213050aaf,
    128'h9090909090900111213141120314099f,
    128'h8080808080808001112131022204088f,
    128'h7070707070707070011121311213077f,
    128'h6060606060606060600111210203066f,
    128'h5050505050505050505001112112055f,
    128'h4040404040404040404040011102044f,
    128'h3030303030303030303030300111033f,
    128'h2020202020202020202020202001022f,
    128'h1010101010101010101010101010011f,
    128'h0000000000000000000000000000000f
  };
  function automatic [7:0] first_digit(input logic [7:0] index);
    first_digit = FIRST_DIGIT_TABLE[{index, 3'b0} +: 8];
  endfunction
  assign launch_lookup = first_digit({top_a, low_b});
  assign launch_digit = divisor_ge16 ? 4'b0 : launch_lookup[3:0];
  assign launch_residual = divisor_ge16 ? top_a : launch_lookup[7:4];

  // 3*abs(b) = 3*(b XOR sign) + (sign ? 3 : 0). Carry-save compression
  // avoids a normalization adder followed by another wide carry chain.
  assign launch_v = {2'b0, b ^ {32{negative_b}}};
  assign launch_twice_v = launch_v << 1;
  assign launch_correction = negative_b ? 34'd3 : 34'd0;
  assign launch_sum = launch_twice_v ^ launch_v ^ launch_correction;
  assign launch_carry = ((launch_twice_v & launch_v)
                      | (launch_twice_v & launch_correction)
                      | (launch_v & launch_correction)) << 1;
  assign launch_3x = launch_sum + launch_carry;

  // The second nibble has a prefix <=255. The D>=256 bypass keeps that
  // prefix; otherwise two small radix-4 steps consume it without a prep clock.
  function automatic [9:0] narrow_radix4_step(
    input logic [9:0] trial, divisor1, divisor2, divisor3
  );
    /* verilator lint_off UNUSEDSIGNAL */
    logic [10:0] difference1, difference2, difference3;
    /* verilator lint_on UNUSEDSIGNAL */
    logic fit0, fit1, fit2, fit3;
    logic [7:0] residual;
    logic [1:0] digit;
    begin
      difference1 = {1'b0, trial} - {1'b0, divisor1};
      difference2 = {1'b0, trial} - {1'b0, divisor2};
      difference3 = {1'b0, trial} - {1'b0, divisor3};
      fit3 = !difference3[10];
      fit2 = !difference2[10] && difference3[10];
      fit1 = !difference1[10] && difference2[10];
      fit0 = difference1[10];
      residual = (difference3[7:0] & {8{fit3}})
               | (difference2[7:0] & {8{fit2}})
               | (difference1[7:0] & {8{fit1}})
               | (trial[7:0] & {8{fit0}});
      digit = {fit3 | fit2, fit3 | fit1};
      narrow_radix4_step = {residual, digit};
    end
  endfunction

  logic [9:0] narrow_1x, narrow_2x;
  logic [7:0] narrow_r1, narrow_r2, group_zero_residual;
  logic [1:0] narrow_digit1, narrow_digit2;
  logic [3:0] group_zero_digit;
  assign narrow_1x = {2'b0, divisor_q[7:0]};
  assign narrow_2x = {1'b0, divisor_q[7:0], 1'b0};
  assign {narrow_r1, narrow_digit1} = narrow_radix4_step(
      {4'b0, remainder_q[3:0], quotient_q[31:30]},
      narrow_1x, narrow_2x, divisor_3x_q[9:0]);
  assign {narrow_r2, narrow_digit2} = narrow_radix4_step(
      {narrow_r1, quotient_q[29:28]},
      narrow_1x, narrow_2x, divisor_3x_q[9:0]);
  assign group_zero_digit = (|divisor_q[31:8]) ? 4'b0 : {narrow_digit1, narrow_digit2};
  assign group_zero_residual = (|divisor_q[31:8])
                            ? {remainder_q[3:0], quotient_q[31:28]} : narrow_r2;

  function automatic [35:0] csa3(
    input logic [35:0] x, y, z
  );
    logic [35:0] sum_bits, carry_bits;
    begin
      sum_bits = x ^ y ^ z;
      carry_bits = ((x & y) | (x & z) | (y & z)) << 1;
      csa3 = sum_bits + carry_bits;
    end
  endfunction

  logic [35:0] divisor_wide, multiples [1:15], multiples_q [1:15];
  assign divisor_wide = {4'b0, divisor_q};
  always_comb begin
    multiples[1] = divisor_wide;
    multiples[3] = {2'b0, divisor_3x_q};
    multiples[5] = divisor_wide + (divisor_wide << 2);
    multiples[7] = (divisor_wide << 3) - divisor_wide;
    multiples[9] = divisor_wide + (divisor_wide << 3);
    multiples[11] = csa3(divisor_wide, divisor_wide << 1, divisor_wide << 3);
    multiples[13] = csa3(divisor_wide, divisor_wide << 2, divisor_wide << 3);
    multiples[15] = (divisor_wide << 4) - divisor_wide;
    for (int k = 2; k <= 14; k = k + 2) multiples[k] = multiples[k/2] << 1;
  end

  // All fifteen trials run in parallel at full width. Adjacent fits make
  // one-hot masks; balanced OR trees select digit and residual together.
  logic [35:0] trial;
  logic [36:0] differences [1:15];
  logic [15:0] fits, select_digit;
  logic [39:0] masked [0:15], tree1 [0:7], tree2 [0:3], tree3 [0:1];
  /* verilator lint_off UNUSEDSIGNAL */
  logic [39:0] selected;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] next_quotient, next_remainder;
  assign trial = {remainder_q, quotient_q[31:28]};
  assign fits[0] = 1'b1;
  assign select_digit[15] = fits[15];
  assign masked[0] = {4'b0, trial} & {40{select_digit[0]}};
  for (genvar k = 1; k <= 15; k = k + 1) begin : parallel_trials
    localparam logic [3:0] DIGIT = 4'(k);
    assign differences[k] = {1'b0, trial} - {1'b0, multiples_q[k]};
    assign fits[k] = !differences[k][36];
    assign masked[k] = {DIGIT, differences[k][35:0]} & {40{select_digit[k]}};
  end
  for (genvar k = 0; k < 15; k = k + 1) begin : adjacent_selection
    assign select_digit[k] = fits[k] && !fits[k+1];
  end
  for (genvar k = 0; k < 8; k = k + 1) begin : reduce1
    assign tree1[k] = masked[2*k] | masked[2*k+1];
  end
  for (genvar k = 0; k < 4; k = k + 1) begin : reduce2
    assign tree2[k] = tree1[2*k] | tree1[2*k+1];
  end
  for (genvar k = 0; k < 2; k = k + 1) begin : reduce3
    assign tree3[k] = tree2[2*k] | tree2[2*k+1];
  end
  assign selected = tree3[0] | tree3[1];
  assign next_quotient = {quotient_q[27:0], selected[39:36]};
  assign next_remainder = selected[31:0];
  assign result = (select_remainder_q ? remainder_negative_q : quotient_negative_q)
                    ? (32'b0 - result_magnitude_q) : result_magnitude_q;
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      busy <= 1'b0;
      result_valid <= 1'b0;
      group_q <= 3'b0;
`ifdef RISCV_FORMAL_ALTOPS
      result <= 32'b0;
      alt_result_q <= 32'b0;
`else
      quotient_q <= 32'b0;
      remainder_q <= 32'b0;
      divisor_q <= 32'b0;
      divisor_3x_q <= 34'b0;
      result_magnitude_q <= 32'b0;
      quotient_negative_q <= 1'b0;
      remainder_negative_q <= 1'b0;
      divisor_negative_q <= 1'b0;
      select_remainder_q <= 1'b0;
      for (int k = 1; k <= 15; k = k + 1) multiples_q[k] <= 36'b0;
`endif
    end else begin
      if (result_accept) result_valid <= 1'b0;
      // Acceptance and a standalone new launch may share an edge.
      if (start && !busy && (!result_valid || result_accept)) begin
        busy <= 1'b1;
        result_valid <= 1'b0;
        group_q <= 3'b0;
`ifdef RISCV_FORMAL_ALTOPS
        alt_result_q <= launch_result;
`else
        quotient_q <= {initial_a[27:0], launch_digit};
        remainder_q <= {28'b0, launch_residual};
        divisor_q <= initial_b;
        divisor_3x_q <= launch_3x;
        quotient_negative_q <= signed_op && (a[31] ^ b[31]) && (b != 32'b0);
        remainder_negative_q <= negative_a;
        divisor_negative_q <= negative_b;
        select_remainder_q <= (op == ALU_REM || op == ALU_REMU);
`endif
      end else if (busy) begin
`ifndef RISCV_FORMAL_ALTOPS
        if (group_q == 3'd0) begin
          quotient_q <= {quotient_q[27:0], group_zero_digit};
          remainder_q <= {24'b0, group_zero_residual};
          for (int k = 1; k <= 15; k = k + 1) multiples_q[k] <= multiples[k];
        end else begin
          quotient_q <= next_quotient;
          remainder_q <= next_remainder;
        end
`endif
        if (group_q == 3'd6) begin
          busy <= 1'b0;
          result_valid <= 1'b1;
`ifdef RISCV_FORMAL_ALTOPS
          result <= alt_result_q;
`else
          result_magnitude_q <= select_remainder_q ? next_remainder : next_quotient;
`endif
        end else begin
          group_q <= group_q + 3'd1;
        end
      end
    end
  end
endmodule
