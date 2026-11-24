// rtl/alu.sv
//
// Base integer results are combinational. DIV/REM share a blocking
// divider. Small magnitudes use a reciprocal ROM and two multipliers.
// Large magnitudes consume seven radix-8, radix-4 or radix-2 digits.
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
  input  logic        div_req_valid,
  output logic        div_req_ready,
  output logic        div_resp_valid,
  input  logic        div_resp_ready,
  output logic [31:0] div_result,
  output logic [31:0] div_magnitude,
  output logic        div_negate,
  output div_completion_t div_completion
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

      default:    out = 32'b0;
    endcase
  end

  // A request advances through setup (bit 0) and six rounds (bits 1..6).
  logic [6:0] phase_q;
  logic       div_issue, div_transfer;
  assign div_req_ready = (phase_q == '0) && !div_resp_valid;
  assign div_issue     = div_req_valid && div_req_ready;
  assign div_transfer  = div_resp_valid && div_resp_ready;

  always_ff @(posedge clock) begin
    if (reset) begin
      phase_q        <= '0;
      div_resp_valid <= 1'b0;
    end else begin
      phase_q        <= {phase_q[5:0], div_issue};
      div_resp_valid <= phase_q[6] || (div_resp_valid && !div_resp_ready);
    end
  end

`ifdef RISCV_FORMAL_ALTOPS
  assign div_negate = 1'b0;
  assign div_completion.take_small      = 1'b1;
  assign div_completion.take_quotient   = 1'b0;
  assign div_completion.take_remainder  = 1'b0;
  assign div_completion.large_quotient  = '0;
  assign div_completion.large_remainder = '0;
  always_ff @(posedge clock) begin
    if (div_issue) begin
      case (op)
        ALU_DIV:  div_magnitude <= (a - b) ^ 32'h7f8529ec;
        ALU_DIVU: div_magnitude <= (a - b) ^ 32'h10e8fd70;
        ALU_REM:  div_magnitude <= (a - b) ^ 32'h8da68fa5;
        ALU_REMU: div_magnitude <= (a - b) ^ 32'h3138d0e1;
        default:  div_magnitude <= '0;
      endcase
    end
    if (div_transfer) div_completion.small_value <= div_magnitude;
  end
`else
  logic signed_op, rem_op, a_negative, b_negative, rem_op_q;
  logic [31:0] dividend_q, divisor_q;
  assign signed_op  = (op == ALU_DIV) || (op == ALU_REM);
  assign rem_op     = (op == ALU_REM) || (op == ALU_REMU);
  assign a_negative = signed_op && a[31];
  assign b_negative = signed_op && b[31];

  always_ff @(posedge clock) begin
    if (div_issue) begin
      dividend_q <= a_negative ? -a : a;
      divisor_q  <= b_negative ? -b : b;
      rem_op_q   <= rem_op;
      div_negate <= rem_op ? a_negative : ((a_negative ^ b_negative) && b != 0);
    end
    if (phase_q[0]) begin
      div_completion.take_small     <= divisor_q[31:11] == 0;
      div_completion.take_quotient  <= divisor_q[31:11] != 0 && !rem_op_q;
      div_completion.take_remainder <= divisor_q[31:11] != 0 && rem_op_q;
    end
  end

  // Small divisors. The registered ROM read is the setup clock.
  (* syn_romstyle = "block_rom" *) logic [31:0] reciprocal_rom [0:2047];
  logic [31:0] reciprocal_q;
  initial begin
    // Initialize two rows per iteration within Gowin's loop unroll limit.
    for (int unsigned i = 0; i < 1024; i++) begin
      if (i < 2) reciprocal_rom[i] = 0;
      else reciprocal_rom[i] = 32'(64'h1_0000_0000 / 64'(i));
      reciprocal_rom[1024+i] = 32'(64'h1_0000_0000 / (64'd1024 + 64'(i)));
    end
  end
  always_ff @(posedge clock)
    if (phase_q[0]) reciprocal_q <= reciprocal_rom[divisor_q[10:0]];

  // In rounds 1 and 2 each multiplier takes one limb of N against
  // successive limbs of M. In round 5 the low multiplier computes q0*D.
  logic [31:0] high_accum_q, low_product_q, high_product_q;
  logic [15:0] low_a, low_b, reciprocal_limb;
  assign reciprocal_limb = phase_q[2] ? reciprocal_q[31:16] : reciprocal_q[15:0];
  assign low_a = phase_q[5] ? {4'b0, high_accum_q[11:0]} : dividend_q[15:0];
  assign low_b = phase_q[5] ? {5'b0, divisor_q[10:0]} : reciprocal_limb;

  always_ff @(posedge clock) begin
    if (phase_q[1] || phase_q[2] || phase_q[5]) low_product_q <= low_a * low_b;
    if (phase_q[1] || phase_q[2]) high_product_q <= dividend_q[31:16] * reciprocal_limb;
  end

  function automatic logic [31:0] sum_three(input logic [31:0] x, y, z);
    sum_three = (x ^ y ^ z) + (((x & y) | (x & z) | (y & z)) << 1);
  endfunction

  logic [15:0] ll_upper_q;
  logic [31:0] hl_q;
  logic [31:0] small_value;
  logic [1:0] middle_carry_q;
  logic [11:0] small_residual_q;
  logic [10:0] corrected_residual;
  logic correction_borrow, unused_residual_msb;
  logic trivial_q, small_rem_q, return_dividend_q, return_ones_q;

  always_ff @(posedge clock) begin
    if (phase_q[0]) begin
      trivial_q <= divisor_q[10:1] == 0;
      small_rem_q <= rem_op_q && divisor_q[10:1] != 0;
      // D=0 returns (all ones, N), D=1 returns (N, zero).
      return_dividend_q <= rem_op_q ^ divisor_q[0];
      return_ones_q <= !rem_op_q && !divisor_q[0];
    end
    if (phase_q[2]) begin
      ll_upper_q <= low_product_q[31:16];
      hl_q       <= high_product_q;
    end
    if (phase_q[3]) begin
      middle_carry_q <= 2'(sum_three({16'b0, ll_upper_q}, {16'b0, hl_q[15:0]},
                                     {16'b0, low_product_q[15:0]}) >> 16);
      high_accum_q <= sum_three(high_product_q, {16'b0, hl_q[31:16]},
                                {16'b0, low_product_q[31:16]});
    end else if (phase_q[4]) begin
      high_accum_q <= trivial_q ? (({32{return_dividend_q}} & dividend_q) | {32{return_ones_q}})
                                : high_accum_q + {30'b0, middle_carry_q};
    end else if (div_transfer) high_accum_q <= small_value;
    if (phase_q[6]) small_residual_q <= dividend_q[11:0] - low_product_q[11:0];
  end

  // N - q0*D < 2D < 4096, so the low 12 bits contain the full residual.
  // The extra subtraction bit distinguishes an exact q0 from one low.
  assign {correction_borrow, unused_residual_msb, corrected_residual} =
      {1'b0, small_residual_q} - {2'b0, divisor_q[10:0]};
  assign small_value = small_rem_q
      ? {21'b0, (correction_borrow ? small_residual_q[10:0] : corrected_residual)}
      : ((!trivial_q && !correction_borrow) ? high_accum_q + 32'd1 : high_accum_q);

  // Large divisors. Seed with the prefix above the seven remaining digits.
  // Each 3-bit slot initially holds dividend bits and later a quotient digit.
  logic setup_oct, setup_quad, oct_q, quad_q, bin_q;
  logic [20:0] slots_q, quad_slots, bin_slots;
  logic [31:0] remainder_q;
  logic [31:0] remainder_next;
  logic [2:0] digit;
  assign setup_oct  = divisor_q[31:18] == 0;
  assign setup_quad = !setup_oct && divisor_q[31:25] == 0;
  for (genvar i = 0; i < 7; i++) begin : gen_slots
    assign quad_slots[3*i +: 3] = {1'b0, dividend_q[2*i +: 2]};
    assign bin_slots[3*i +: 3]  = {2'b0, dividend_q[i]};
  end

  always_ff @(posedge clock) begin
    if (phase_q[0]) begin
      oct_q  <= setup_oct;
      quad_q <= setup_quad;
      bin_q  <= divisor_q[31:25] != 0;
      slots_q <= setup_oct ? dividend_q[20:0] : setup_quad ? quad_slots : bin_slots;
      remainder_q <= setup_oct ? {21'b0, dividend_q[31:21]} :
                    setup_quad ? {14'b0, dividend_q[31:14]} : {7'b0, dividend_q[31:7]};
    end else if ((|phase_q[6:1]) || div_transfer) begin
      slots_q <= {slots_q[17:0], digit};
      remainder_q <= remainder_next;
    end
  end

  // An enabled trial sees at most 32 bits in radix 2, 27 bits in radix 4
  // and 21 bits in radix 8. The same bounds cover its divisor multiple.
  logic [31:0] partial_dividend, multiple [1:7];
  logic [20:0] oct_partial;
  logic [26:0] triple_q;
  logic [20:0] quintuple_q, septuple_q;
  assign oct_partial = {remainder_q[17:0], slots_q[20:18]};
  assign partial_dividend =
        ({32{oct_q}}  & {11'b0, oct_partial})
      | ({32{quad_q}} & {5'b0, remainder_q[24:0], slots_q[19:18]})
      | ({32{bin_q}}  & {remainder_q[30:0], slots_q[18]});

  always_ff @(posedge clock) begin
    if (phase_q[0]) begin
      triple_q    <= {1'b0, divisor_q[24:0], 1'b0} + {2'b0, divisor_q[24:0]};
      quintuple_q <= {1'b0, divisor_q[17:0], 2'b0} + {3'b0, divisor_q[17:0]};
      septuple_q  <= {divisor_q[17:0], 3'b0} - {3'b0, divisor_q[17:0]};
    end
  end
  assign multiple[1] = divisor_q;
  assign multiple[2] = {6'b0, divisor_q[24:0], 1'b0};
  assign multiple[3] = {5'b0, triple_q};
  assign multiple[4] = {12'b0, divisor_q[17:0], 2'b0};
  assign multiple[5] = {11'b0, quintuple_q};
  assign multiple[6] = {11'b0, triple_q[19:0], 1'b0};
  assign multiple[7] = {11'b0, septuple_q};

  logic [7:1] fits;
  logic [7:0] select_digit;
  logic [31:0] residual [0:7];
  for (genvar k = 1; k <= 7; k++) begin : gen_trial
    localparam integer W = (k == 1) ? 32 : (k < 4) ? 27 : 21;
    logic [W:0] difference;
    logic [W-1:0] partial;
    assign partial = (k >= 4) ? W'(oct_partial) : partial_dividend[W-1:0];
    assign difference = {1'b0, partial} - {1'b0, multiple[k][W-1:0]};
    assign fits[k] = !difference[W] && ((k == 1) || ((k < 4) && !bin_q) || oct_q);
    assign residual[k] = 32'({W{select_digit[k]}} & difference[W-1:0]);
  end

  assign select_digit = {fits, 1'b1} & ~{1'b0, fits};
  assign residual[0] = {32{select_digit[0]}} & partial_dividend;
  assign remainder_next = residual[0] | residual[1] | residual[2] | residual[3] |
                          residual[4] | residual[5] | residual[6] | residual[7];
  assign digit = {fits[4], (fits[2] && !fits[4]) || fits[6], |(select_digit & 8'haa)};

  function automatic logic [20:0] unpack_quotient(input logic [20:0] slots,
                                                   input logic oct, quad, bin);
    logic [13:0] quaternary;
    logic [6:0] binary_digits;
    for (int i = 0; i < 7; i++) begin
      quaternary[2*i +: 2] = slots[3*i +: 2];
      binary_digits[i] = slots[3*i];
    end
    unpack_quotient = ({21{oct}} & slots)
                    | {7'b0, {14{quad}} & quaternary} | {14'b0, {7{bin}} & binary_digits};
  endfunction

  // Transfer commits the seventh trial and the reciprocal correction
  // into the working registers. MEM reads them before the next setup.
  assign div_completion.small_value     = high_accum_q;
  assign div_completion.large_quotient  = unpack_quotient(slots_q, oct_q, quad_q, bin_q);
  assign div_completion.large_remainder = remainder_q;

  div_completion_t response;
  always_comb begin
    response = div_completion;
    response.small_value     = small_value;
    response.large_quotient  = unpack_quotient({slots_q[17:0], digit}, oct_q, quad_q, bin_q);
    response.large_remainder = remainder_next;
  end
  assign div_magnitude = divide_magnitude(response);
`endif

  assign div_result = div_negate ? -div_magnitude : div_magnitude;

endmodule
