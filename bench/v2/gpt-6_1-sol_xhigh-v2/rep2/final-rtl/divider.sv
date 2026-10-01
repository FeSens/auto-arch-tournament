// Shared blocking RV32M divider: a small four-bit launch seed, seven
// registered four-bit radix-4 iterations, then response transfer to EX/MEM.
// The final magnitude and sign are registered before sign correction.
// Zero divisors and signed overflow follow the same transaction timing.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        req_valid,
  output logic        req_ready,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        rsp_valid,
  input  logic        rsp_ready,
  output logic [31:0] result
);
  logic busy_q;
  logic [2:0] iteration_q;
  logic [31:0] response_magnitude_q;
  logic response_negative_q;

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] altops_request_q;
`else
  logic [31:0] quotient_q, remainder_q;
  logic [33:0] divisor_q, divisor_twice_q, divisor_thrice_q;
  logic quotient_negative_q, remainder_negative_q, select_remainder_q;
  logic signed_op;
  logic [31:0] dividend_magnitude, divisor_magnitude;
  logic [33:0] divisor_once, divisor_twice;
  logic [7:0] seed;
  logic [63:0] first_step, second_step;

  // Fixed-divisor truth masks factor the launch nibble into LUT4 functions.
  // Bit N of M_D_k is bit k of {N % D, N / D}; D=0 returns {N, 4'hf}.
  // Masks were generated offline with exact integer quotient/remainder.
  // The full-width D >= 16 bypass remains outside this function.
  function automatic [7:0] small_seed(
    input logic [3:0] dividend,
    input logic [3:0] divisor
  );
    localparam logic [15:0] M_0_0 = 16'hffff, M_0_1 = 16'hffff, M_0_2 = 16'hffff, M_0_3 = 16'hffff;
    localparam logic [15:0] M_0_4 = 16'haaaa, M_0_5 = 16'hcccc, M_0_6 = 16'hf0f0, M_0_7 = 16'hff00;
    localparam logic [15:0] M_1_0 = 16'haaaa, M_1_1 = 16'hcccc, M_1_2 = 16'hf0f0, M_1_3 = 16'hff00;
    localparam logic [15:0] M_1_4 = 16'h0000, M_1_5 = 16'h0000, M_1_6 = 16'h0000, M_1_7 = 16'h0000;
    localparam logic [15:0] M_2_0 = 16'hcccc, M_2_1 = 16'hf0f0, M_2_2 = 16'hff00, M_2_3 = 16'h0000;
    localparam logic [15:0] M_2_4 = 16'haaaa, M_2_5 = 16'h0000, M_2_6 = 16'h0000, M_2_7 = 16'h0000;
    localparam logic [15:0] M_3_0 = 16'h8e38, M_3_1 = 16'h0fc0, M_3_2 = 16'hf000, M_3_3 = 16'h0000;
    localparam logic [15:0] M_3_4 = 16'h2492, M_3_5 = 16'h4924, M_3_6 = 16'h0000, M_3_7 = 16'h0000;
    localparam logic [15:0] M_4_0 = 16'hf0f0, M_4_1 = 16'hff00, M_4_2 = 16'h0000, M_4_3 = 16'h0000;
    localparam logic [15:0] M_4_4 = 16'haaaa, M_4_5 = 16'hcccc, M_4_6 = 16'h0000, M_4_7 = 16'h0000;
    localparam logic [15:0] M_5_0 = 16'h83e0, M_5_1 = 16'hfc00, M_5_2 = 16'h0000, M_5_3 = 16'h0000;
    localparam logic [15:0] M_5_4 = 16'h294a, M_5_5 = 16'h318c, M_5_6 = 16'h4210, M_5_7 = 16'h0000;
    localparam logic [15:0] M_6_0 = 16'h0fc0, M_6_1 = 16'hf000, M_6_2 = 16'h0000, M_6_3 = 16'h0000;
    localparam logic [15:0] M_6_4 = 16'haaaa, M_6_5 = 16'hc30c, M_6_6 = 16'h0c30, M_6_7 = 16'h0000;
    localparam logic [15:0] M_7_0 = 16'h3f80, M_7_1 = 16'hc000, M_7_2 = 16'h0000, M_7_3 = 16'h0000;
    localparam logic [15:0] M_7_4 = 16'h952a, M_7_5 = 16'h264c, M_7_6 = 16'h3870, M_7_7 = 16'h0000;
    localparam logic [15:0] M_8_0 = 16'hff00, M_8_1 = 16'h0000, M_8_2 = 16'h0000, M_8_3 = 16'h0000;
    localparam logic [15:0] M_8_4 = 16'haaaa, M_8_5 = 16'hcccc, M_8_6 = 16'hf0f0, M_8_7 = 16'h0000;
    localparam logic [15:0] M_9_0 = 16'hfe00, M_9_1 = 16'h0000, M_9_2 = 16'h0000, M_9_3 = 16'h0000;
    localparam logic [15:0] M_9_4 = 16'h54aa, M_9_5 = 16'h98cc, M_9_6 = 16'he0f0, M_9_7 = 16'h0100;
    localparam logic [15:0] M_10_0 = 16'hfc00, M_10_1 = 16'h0000, M_10_2 = 16'h0000, M_10_3 = 16'h0000;
    localparam logic [15:0] M_10_4 = 16'haaaa, M_10_5 = 16'h30cc, M_10_6 = 16'hc0f0, M_10_7 = 16'h0300;
    localparam logic [15:0] M_11_0 = 16'hf800, M_11_1 = 16'h0000, M_11_2 = 16'h0000, M_11_3 = 16'h0000;
    localparam logic [15:0] M_11_4 = 16'h52aa, M_11_5 = 16'h64cc, M_11_6 = 16'h80f0, M_11_7 = 16'h0700;
    localparam logic [15:0] M_12_0 = 16'hf000, M_12_1 = 16'h0000, M_12_2 = 16'h0000, M_12_3 = 16'h0000;
    localparam logic [15:0] M_12_4 = 16'haaaa, M_12_5 = 16'hcccc, M_12_6 = 16'h00f0, M_12_7 = 16'h0f00;
    localparam logic [15:0] M_13_0 = 16'he000, M_13_1 = 16'h0000, M_13_2 = 16'h0000, M_13_3 = 16'h0000;
    localparam logic [15:0] M_13_4 = 16'h4aaa, M_13_5 = 16'h8ccc, M_13_6 = 16'h10f0, M_13_7 = 16'h1f00;
    localparam logic [15:0] M_14_0 = 16'hc000, M_14_1 = 16'h0000, M_14_2 = 16'h0000, M_14_3 = 16'h0000;
    localparam logic [15:0] M_14_4 = 16'haaaa, M_14_5 = 16'h0ccc, M_14_6 = 16'h30f0, M_14_7 = 16'h3f00;
    localparam logic [15:0] M_15_0 = 16'h8000, M_15_1 = 16'h0000, M_15_2 = 16'h0000, M_15_3 = 16'h0000;
    localparam logic [15:0] M_15_4 = 16'h2aaa, M_15_5 = 16'h4ccc, M_15_6 = 16'h70f0, M_15_7 = 16'h7f00;
    logic [7:0] p0, p1, p2, p3, p4, p5, p6, p7;
    logic [7:0] p8, p9, p10, p11, p12, p13, p14, p15;
    begin
      p0 = (divisor == 4'd0)
          ? {M_0_7[dividend], M_0_6[dividend], M_0_5[dividend], M_0_4[dividend], M_0_3[dividend], M_0_2[dividend], M_0_1[dividend], M_0_0[dividend]} : 8'b0;
      p1 = (divisor == 4'd1)
          ? {M_1_7[dividend], M_1_6[dividend], M_1_5[dividend], M_1_4[dividend], M_1_3[dividend], M_1_2[dividend], M_1_1[dividend], M_1_0[dividend]} : 8'b0;
      p2 = (divisor == 4'd2)
          ? {M_2_7[dividend], M_2_6[dividend], M_2_5[dividend], M_2_4[dividend], M_2_3[dividend], M_2_2[dividend], M_2_1[dividend], M_2_0[dividend]} : 8'b0;
      p3 = (divisor == 4'd3)
          ? {M_3_7[dividend], M_3_6[dividend], M_3_5[dividend], M_3_4[dividend], M_3_3[dividend], M_3_2[dividend], M_3_1[dividend], M_3_0[dividend]} : 8'b0;
      p4 = (divisor == 4'd4)
          ? {M_4_7[dividend], M_4_6[dividend], M_4_5[dividend], M_4_4[dividend], M_4_3[dividend], M_4_2[dividend], M_4_1[dividend], M_4_0[dividend]} : 8'b0;
      p5 = (divisor == 4'd5)
          ? {M_5_7[dividend], M_5_6[dividend], M_5_5[dividend], M_5_4[dividend], M_5_3[dividend], M_5_2[dividend], M_5_1[dividend], M_5_0[dividend]} : 8'b0;
      p6 = (divisor == 4'd6)
          ? {M_6_7[dividend], M_6_6[dividend], M_6_5[dividend], M_6_4[dividend], M_6_3[dividend], M_6_2[dividend], M_6_1[dividend], M_6_0[dividend]} : 8'b0;
      p7 = (divisor == 4'd7)
          ? {M_7_7[dividend], M_7_6[dividend], M_7_5[dividend], M_7_4[dividend], M_7_3[dividend], M_7_2[dividend], M_7_1[dividend], M_7_0[dividend]} : 8'b0;
      p8 = (divisor == 4'd8)
          ? {M_8_7[dividend], M_8_6[dividend], M_8_5[dividend], M_8_4[dividend], M_8_3[dividend], M_8_2[dividend], M_8_1[dividend], M_8_0[dividend]} : 8'b0;
      p9 = (divisor == 4'd9)
          ? {M_9_7[dividend], M_9_6[dividend], M_9_5[dividend], M_9_4[dividend], M_9_3[dividend], M_9_2[dividend], M_9_1[dividend], M_9_0[dividend]} : 8'b0;
      p10 = (divisor == 4'd10)
          ? {M_10_7[dividend], M_10_6[dividend], M_10_5[dividend], M_10_4[dividend], M_10_3[dividend], M_10_2[dividend], M_10_1[dividend], M_10_0[dividend]} : 8'b0;
      p11 = (divisor == 4'd11)
          ? {M_11_7[dividend], M_11_6[dividend], M_11_5[dividend], M_11_4[dividend], M_11_3[dividend], M_11_2[dividend], M_11_1[dividend], M_11_0[dividend]} : 8'b0;
      p12 = (divisor == 4'd12)
          ? {M_12_7[dividend], M_12_6[dividend], M_12_5[dividend], M_12_4[dividend], M_12_3[dividend], M_12_2[dividend], M_12_1[dividend], M_12_0[dividend]} : 8'b0;
      p13 = (divisor == 4'd13)
          ? {M_13_7[dividend], M_13_6[dividend], M_13_5[dividend], M_13_4[dividend], M_13_3[dividend], M_13_2[dividend], M_13_1[dividend], M_13_0[dividend]} : 8'b0;
      p14 = (divisor == 4'd14)
          ? {M_14_7[dividend], M_14_6[dividend], M_14_5[dividend], M_14_4[dividend], M_14_3[dividend], M_14_2[dividend], M_14_1[dividend], M_14_0[dividend]} : 8'b0;
      p15 = (divisor == 4'd15)
          ? {M_15_7[dividend], M_15_6[dividend], M_15_5[dividend], M_15_4[dividend], M_15_3[dividend], M_15_2[dividend], M_15_1[dividend], M_15_0[dividend]} : 8'b0;
      small_seed = (((p0 | p1) | (p2 | p3)) |
                    ((p4 | p5) | (p6 | p7))) |
                   (((p8 | p9) | (p10 | p11)) |
                    ((p12 | p13) | (p14 | p15)));
    end
  endfunction

  // Each digit subtracts all three registered multiples concurrently.
  // Zero extension to 35 bits makes the top difference bit a borrow
  // flag, even when 3D exceeds the 32-bit unsigned range.
  function automatic [63:0] radix4_step(
    input logic [31:0] r,
    input logic [31:0] q,
    input logic [33:0] d1,
    input logic [33:0] d2,
    input logic [33:0] d3
  );
    logic [33:0] t;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [34:0] diff1, diff2, diff3;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0] next_r;
    logic [1:0] digit;
    begin
      t = {r, q[31:30]};
      diff1 = {1'b0, t} - {1'b0, d1};
      diff2 = {1'b0, t} - {1'b0, d2};
      diff3 = {1'b0, t} - {1'b0, d3};
      if (!diff3[34]) begin
        digit = 2'd3;
        next_r = diff3[31:0];
      end else if (!diff2[34]) begin
        digit = 2'd2;
        next_r = diff2[31:0];
      end else if (!diff1[34]) begin
        digit = 2'd1;
        next_r = diff1[31:0];
      end else begin
        digit = 2'd0;
        next_r = t[31:0];
      end
      radix4_step = {next_r, q[29:0], digit};
    end
  endfunction

  assign signed_op = (op == ALU_DIV || op == ALU_REM);
  assign dividend_magnitude = (signed_op && a[31]) ? -a : a;
  assign divisor_magnitude = (signed_op && b[31]) ? -b : b;
  assign divisor_once = {2'b0, divisor_magnitude};
  assign divisor_twice = {1'b0, divisor_magnitude, 1'b0};
  assign seed = (divisor_magnitude[31:4] != 0)
              ? {dividend_magnitude[31:28], 4'b0}
              : small_seed(dividend_magnitude[31:28], divisor_magnitude[3:0]);
  assign first_step = radix4_step(remainder_q, quotient_q,
                                 divisor_q, divisor_twice_q, divisor_thrice_q);
  assign second_step = radix4_step(first_step[63:32], first_step[31:0],
                                  divisor_q, divisor_twice_q, divisor_thrice_q);
`endif

  assign req_ready = !busy_q && !rsp_valid;
  assign result = response_negative_q ? -response_magnitude_q : response_magnitude_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      busy_q <= 1'b0;
      iteration_q <= '0;
      rsp_valid <= 1'b0;
      response_magnitude_q <= '0;
      response_negative_q <= 1'b0;
`ifdef RISCV_FORMAL_ALTOPS
      altops_request_q <= '0;
`else
      quotient_q <= '0;
      remainder_q <= '0;
      divisor_q <= '0;
      divisor_twice_q <= '0;
      divisor_thrice_q <= '0;
      quotient_negative_q <= 1'b0;
      remainder_negative_q <= 1'b0;
      select_remainder_q <= 1'b0;
`endif
    end else begin
      if (rsp_valid && rsp_ready)
        rsp_valid <= 1'b0;

      if (req_valid && req_ready) begin
        busy_q <= 1'b1;
        iteration_q <= '0;
`ifdef RISCV_FORMAL_ALTOPS
        case (op)
          ALU_DIV:  altops_request_q <= (a - b) ^ 32'h7f8529ec;
          ALU_DIVU: altops_request_q <= (a - b) ^ 32'h10e8fd70;
          ALU_REM:  altops_request_q <= (a - b) ^ 32'h8da68fa5;
          ALU_REMU: altops_request_q <= (a - b) ^ 32'h3138d0e1;
          default:  altops_request_q <= '0;
        endcase
`else
        quotient_q <= {dividend_magnitude[27:0], seed[3:0]};
        remainder_q <= {28'b0, seed[7:4]};
        divisor_q <= divisor_once;
        divisor_twice_q <= divisor_twice;
        divisor_thrice_q <= divisor_once + divisor_twice;
        // D=0 chooses digit 3 throughout. Its all-ones quotient must
        // never be negated; REM still restores the dividend's sign.
        quotient_negative_q <= signed_op && (a[31] ^ b[31]) && (b != 0);
        remainder_negative_q <= signed_op && a[31];
        select_remainder_q <= (op == ALU_REM || op == ALU_REMU);
`endif
      end else if (busy_q) begin
`ifndef RISCV_FORMAL_ALTOPS
        quotient_q <= second_step[31:0];
        remainder_q <= second_step[63:32];
`endif
        if (iteration_q == 3'd6) begin
          busy_q <= 1'b0;
          rsp_valid <= 1'b1;
`ifdef RISCV_FORMAL_ALTOPS
          response_magnitude_q <= altops_request_q;
          response_negative_q <= 1'b0;
`else
          response_magnitude_q <= select_remainder_q ? second_step[63:32]
                                                    : second_step[31:0];
          response_negative_q <= select_remainder_q ? remainder_negative_q
                                                   : quotient_negative_q;
`endif
        end else begin
          iteration_q <= iteration_q + 3'd1;
        end
      end
    end
  end
endmodule
