// rtl/alu.sv
//
// EX computes integer results. After six wait clocks, div_valid lets EX
// transfer the divide instruction. That edge finishes the last digit,
// and div_result supplies the resident MEM slot until the next issue.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module alu (
  input  logic        clock,
  input  logic        reset,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out,
  input  logic        div_request,
  output logic        div_ready,
  output logic        div_valid,
  output logic [31:0] div_result,
  input  logic        div_consume
);

  logic        [4:0]  shamt;

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

  logic [2:0] groups_left;
  logic       div_start;
  assign div_ready = (groups_left == 0) && !div_valid;
  assign div_start = div_request && div_ready;

  always_ff @(posedge clock) begin
    if (reset) begin
      groups_left <= 3'd0;
      div_valid   <= 1'b0;
    end else if (div_start) begin
      groups_left <= 3'd6;
    end else if (groups_left != 0) begin
      groups_left <= groups_left - 3'd1;
      div_valid   <= (groups_left == 3'd1);
    end else if (div_consume) begin
      div_valid <= 1'b0;
    end
  end

`ifdef RISCV_FORMAL_ALTOPS
  always_ff @(posedge clock) begin
    if (div_start) begin
      case (op)
        ALU_DIV:  div_result <= (a - b) ^ 32'h7f8529ec;
        ALU_DIVU: div_result <= (a - b) ^ 32'h10e8fd70;
        ALU_REM:  div_result <= (a - b) ^ 32'h8da68fa5;
        default:  div_result <= (a - b) ^ 32'h3138d0e1; // REMU
      endcase
    end
  end
`else
  logic [31:0] divisor_q, quotient_q, remainder_q;
  logic [34:0] triple_q, quintuple_q, septuple_q;
  logic [34:0] wide_multiple [1:7];
  logic [18:0] narrow_divisor, narrow_odd [0:15]; // (2*k + 1)*D
  logic [1:0]  prefix, first_digit, first_remainder;
  logic        narrow, narrow_q, zero_divisor;
  logic [34:0] wide_trial;
  logic [18:0] narrow_trial;
  logic [8:0]  wide_fit;
  logic [32:0] narrow_fit;
  logic [7:0]  wide_select;
  logic [31:0] narrow_select;
  logic [31:0] wide_difference [0:7], wide_remainder;
  logic [13:0] narrow_difference [0:31], narrow_remainder;
  logic [2:0]  wide_digit;
  logic [4:0]  narrow_digit;
  logic        want_remainder, a_negative, b_negative;
  logic        remainder_op_q, negate_q;
  logic [31:0] magnitude;

  assign want_remainder = (op == ALU_REM) || (op == ALU_REMU);
  assign a_negative = ((op == ALU_DIV) || (op == ALU_REM)) && a[31];
  assign b_negative = ((op == ALU_DIV) || (op == ALU_REM)) && b[31];

  // For 0 < D < 2^14, resolve two bits in setup. For larger D, the
  // top 14 dividend bits are already a legal remainder with zero quotient.
  assign zero_divisor = divisor_q == 0;
  assign narrow = divisor_q[31:14] == 0 && !zero_divisor;
  assign prefix = quotient_q[31:30];
  always_comb begin
    first_digit = 2'd0;
    first_remainder = prefix;
    case (divisor_q)
      32'd1: begin
        first_digit = prefix;
        first_remainder = 2'd0;
      end
      32'd2: begin
        first_digit = {1'b0, prefix[1]};
        first_remainder = {1'b0, prefix[0]};
      end
      32'd3: if (prefix == 2'd3) begin
        first_digit = 2'd1;
        first_remainder = 2'd0;
      end
      default: ;
    endcase
  end

  assign wide_multiple[1] = {3'b0, divisor_q};
  assign wide_multiple[2] = {2'b0, divisor_q, 1'b0};
  assign wide_multiple[3] = triple_q;
  assign wide_multiple[4] = {1'b0, divisor_q, 2'b0};
  assign wide_multiple[5] = quintuple_q;
  assign wide_multiple[6] = triple_q << 1;
  assign wide_multiple[7] = septuple_q;

  // Compress three shifted copies to a single carry-propagate addition.
  function automatic logic [18:0] sum3(input logic [18:0] x, y, z);
    logic [18:0] xy;
    xy = x ^ y;
    sum3 = (xy ^ z) + (((x & y) | (xy & z)) << 1);
  endfunction

  assign narrow_divisor = {5'b0, divisor_q[13:0]};
  assign narrow_odd[0] = narrow_divisor;
  assign narrow_odd[1] = triple_q[18:0];
  assign narrow_odd[2] = quintuple_q[18:0];
  assign narrow_odd[3] = septuple_q[18:0];
  always_ff @(posedge clock) begin
    if (groups_left == 3'd6) begin
      triple_q    <= wide_multiple[2] + wide_multiple[1];
      quintuple_q <= wide_multiple[4] + wide_multiple[1];
      septuple_q  <= {divisor_q, 3'b0} - wide_multiple[1];
      narrow_odd[4]  <= (narrow_divisor << 3) + narrow_divisor;
      narrow_odd[5]  <= sum3(narrow_divisor << 3, narrow_divisor << 1, narrow_divisor);
      narrow_odd[6]  <= sum3(narrow_divisor << 3, narrow_divisor << 2, narrow_divisor);
      narrow_odd[7]  <= (narrow_divisor << 4) - narrow_divisor;
      narrow_odd[8]  <= (narrow_divisor << 4) + narrow_divisor;
      narrow_odd[9]  <= sum3(narrow_divisor << 4, narrow_divisor << 1, narrow_divisor);
      narrow_odd[10] <= sum3(narrow_divisor << 4, narrow_divisor << 2, narrow_divisor);
      narrow_odd[11] <= 19'd23 * narrow_divisor;
      narrow_odd[12] <= sum3(narrow_divisor << 4, narrow_divisor << 3, narrow_divisor);
      narrow_odd[13] <= 19'd27 * narrow_divisor;
      narrow_odd[14] <= 19'd29 * narrow_divisor;
      narrow_odd[15] <= (narrow_divisor << 5) - narrow_divisor;
    end
  end

  assign wide_trial   = {remainder_q, quotient_q[31:29]};
  assign narrow_trial = {remainder_q[13:0], quotient_q[31:27]};
  assign wide_fit[0] = 1'b1;
  assign wide_fit[8] = 1'b0;
  assign wide_difference[0] = wide_trial[31:0];
  for (genvar j = 1; j < 8; j++) begin : g_wide_trial
    logic borrow;
    logic [2:0] unused_high;
    assign {borrow, unused_high, wide_difference[j]} =
        {1'b0, wide_trial} - {1'b0, wide_multiple[j]};
    assign wide_fit[j] = !borrow;
  end

  assign narrow_fit[32] = 1'b0;
  for (genvar k = 0; k < 32; k++) begin : g_narrow_trial
    if (k % 4 == 0) begin : g_shared
      // T32 = 4*T8 + suffix. Subtracting 4*j*D preserves the suffix
      // and borrows exactly when the shared T8 - j*D subtractor borrows.
      assign narrow_fit[k] = wide_fit[k/4];
      assign narrow_difference[k] = {wide_difference[k/4][11:0], quotient_q[28:27]};
    end else begin : g_subtract
      logic [18:0] multiple;
      logic borrow;
      logic [4:0] unused_high;
      assign multiple = (k % 2 == 0) ? narrow_odd[k/4] << 1 : narrow_odd[k/2];
      assign {borrow, unused_high, narrow_difference[k]} =
          {1'b0, narrow_trial} - {1'b0, multiple};
      assign narrow_fit[k] = !borrow;
    end
  end

  assign wide_select   = wide_fit[7:0] & ~wide_fit[8:1];
  assign narrow_select = narrow_fit[31:0] & ~narrow_fit[32:1];
  // The wide digit supplies the upper three bits of the narrow digit
  // because wide_fit[j] marks the first of four candidates 4*j..4*j+3.
  assign wide_digit = {wide_fit[4], (wide_fit[2] && !wide_fit[4]) || wide_fit[6],
                       |(wide_select & 8'haa)};
  assign narrow_digit = {wide_digit, |(narrow_select & 32'hcccccccc),
                                     |(narrow_select & 32'haaaaaaaa)};

  for (genvar bidx = 0; bidx < 32; bidx++) begin : g_wide_residual
    logic [7:0] bits_at_index;
    for (genvar j = 0; j < 8; j++) begin : g_bit
      assign bits_at_index[j] = wide_difference[j][bidx];
    end
    assign wide_remainder[bidx] = |(wide_select & bits_at_index);
  end
  for (genvar bidx = 0; bidx < 14; bidx++) begin : g_narrow_residual
    logic [7:0] group_bits;
    for (genvar j = 0; j < 8; j++) begin : g_group
      logic [3:0] bits_at_index;
      for (genvar i = 0; i < 4; i++) begin : g_bit
        assign bits_at_index[i] = narrow_difference[4*j + i][bidx];
      end
      assign group_bits[j] = |(narrow_select[4*j +: 4] & bits_at_index);
    end
    assign narrow_remainder[bidx] = |group_bits;
  end

  logic setup, step_narrow, step_wide;
  logic [31:0] seed_quotient, seed_remainder;
  // Decode the write-side selects in parallel with both trial banks.
  assign setup = groups_left == 3'd6;
  assign step_narrow = !setup && narrow_q;
  assign step_wide   = !setup && !narrow_q;
  // For D=0, seed 14 quotient ones. The six radix-8 steps append the
  // other 18 ones and shift the entire dividend into R.
  assign seed_quotient  = narrow ? {quotient_q[29:0], first_digit}
                                 : {quotient_q[17:0], {14{zero_divisor}}};
  assign seed_remainder = narrow ? {30'b0, first_remainder} : {18'b0, quotient_q[31:18]};

  always_ff @(posedge clock) begin
    if (setup) narrow_q <= narrow;
    if (div_start) begin
      quotient_q     <= a_negative ? -a : a;
      divisor_q      <= b_negative ? -b : b;
      remainder_op_q <= want_remainder;
      // All trials fit D=0, so the quotient needs no sign correction.
      // INT_MIN / -1 already gives the required 32-bit pattern.
      negate_q <= want_remainder ? a_negative : ((a_negative ^ b_negative) && b != 0);
    end else if (groups_left != 0 || (div_valid && div_consume)) begin
      quotient_q  <= ({32{setup}} & seed_quotient)
                   | ({32{step_narrow}} & {quotient_q[26:0], narrow_digit})
                   | ({32{step_wide}}   & {quotient_q[28:0], wide_digit});
      remainder_q <= ({32{setup}} & seed_remainder)
                   | {18'b0, {14{step_narrow}} & narrow_remainder}
                   | ({32{step_wide}} & wide_remainder);
    end
  end

  // Sign correction uses the registered final group, outside the recurrence.
  assign magnitude = remainder_op_q ? remainder_q : quotient_q;
  assign div_result = negate_q ? -magnitude : magnitude;
`endif

endmodule

/* verilator lint_off DECLFILENAME */
module mul_product (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);
/* verilator lint_on DECLFILENAME */
`ifdef RISCV_FORMAL_ALTOPS
  always_comb begin
    case (op)
      ALU_MUL:    out = (a + b) ^ 32'h5876063e;
      ALU_MULH:   out = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  out = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: out = (a - b) ^ 32'hecfbe137;
      default:    out = 32'b0;
    endcase
  end
`else
  logic signed [32:0] lhs, rhs;
  logic signed [63:0] product;

  assign lhs = $signed({a[31] && (op == ALU_MULH || op == ALU_MULHSU), a});
  assign rhs = $signed({b[31] && op == ALU_MULH, b});
  assign product = lhs * rhs;
  assign out = op == ALU_MUL ? product[31:0] : product[63:32];
`endif
endmodule
