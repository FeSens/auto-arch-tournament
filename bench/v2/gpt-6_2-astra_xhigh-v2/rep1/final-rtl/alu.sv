// rtl/alu.sv
//
// RV32IM ALU. Division takes one issue cycle, one setup cycle, five
// arithmetic cycles and one result transfer cycle.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module alu #(
  parameter bit ENABLE_MUL = 1'b1
) (
  input  logic        clock,
  input  logic        reset,
  input  logic        div_request,
  output logic        div_busy,
  output logic        div_done,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  logic        [4:0]  shamt;

  // Phase 0 accepts a request. Phases 1 through 6 run the divider.
  // In phase 7 EX owns an empty EX/MEM slot and consumes the result.
  logic [2:0] phase_q;
  logic div_issue;
  logic [31:0] div_result;
  assign div_busy  = phase_q != 3'd0;
  assign div_done  = phase_q == 3'd7;
  assign div_issue = div_request && !div_busy;

  always_ff @(posedge clock) begin
    if (reset) phase_q <= 3'd0;
    else if (div_request || div_busy) phase_q <= phase_q + 3'd1;
  end

`ifdef RISCV_FORMAL_ALTOPS
  always_ff @(posedge clock) begin
    if (div_issue) begin
      case (op)
        ALU_DIV:  div_result <= (a - b) ^ 32'h7f8529ec;
        ALU_DIVU: div_result <= (a - b) ^ 32'h10e8fd70;
        ALU_REM:  div_result <= (a - b) ^ 32'h8da68fa5;
        default:  div_result <= (a - b) ^ 32'h3138d0e1; // REMU
      endcase
    end
  end
`else
  logic signed_div, want_rem, neg_a, neg_b;
  assign signed_div = op == ALU_DIV || op == ALU_REM;
  assign want_rem   = op == ALU_REM || op == ALU_REMU;
  assign neg_a      = signed_div && a[31];
  assign neg_b      = signed_div && b[31];

  logic [31:0] dividend_q, divisor_q;
  logic want_rem_q, negate_q;
  always_ff @(posedge clock) begin
    if (div_issue) begin
      dividend_q  <= neg_a ? -a : a;
      divisor_q   <= neg_b ? -b : b;
      want_rem_q  <= want_rem;
      negate_q    <= want_rem ? neg_a : ((neg_a ^ neg_b) && b != 0);
    end
  end

  logic radix8_q, small_q, zero_q;
  wire use_radix8 = |divisor_q[31:17];
  wire [34:0] d = {3'b0, divisor_q};
  wire [20:0] narrow_d = {4'b0, divisor_q[16:0]};
  logic [34:0] triple_q, quintuple_q, septuple_q;
  logic [20:0] nine_q, eleven_q, thirteen_q, fifteen_q;
  always_ff @(posedge clock) begin
    if (phase_q == 3'd1) begin
      radix8_q    <= use_radix8;
      small_q     <= divisor_q[31:12] == 0;
      zero_q      <= divisor_q == 0;
      triple_q    <= (d << 1) + d;
      quintuple_q <= (d << 2) + d;
      septuple_q  <= (d << 3) - d;
      nine_q      <= (narrow_d << 3) + narrow_d;
      eleven_q    <= (narrow_d << 3) + (narrow_d << 1) + narrow_d;
      thirteen_q  <= (narrow_d << 4) - (narrow_d << 1) - narrow_d;
      fifteen_q   <= (narrow_d << 4) - narrow_d;
    end
  end

  wire [34:0] multiple [1:7];
  assign multiple[1] = d;
  assign multiple[2] = d << 1;
  assign multiple[3] = triple_q;
  assign multiple[4] = d << 2;
  assign multiple[5] = quintuple_q;
  assign multiple[6] = triple_q << 1;
  assign multiple[7] = septuple_q;
  wire [20:0] upper [8:15];
  assign upper[8]  = narrow_d << 3;
  assign upper[9]  = nine_q;
  assign upper[10] = quintuple_q[20:0] << 1;
  assign upper[11] = eleven_q;
  assign upper[12] = triple_q[20:0] << 2;
  assign upper[13] = thirteen_q;
  assign upper[14] = septuple_q[20:0] << 1;
  assign upper[15] = fifteen_q;

  // A trial is bounded by the dividend prefix processed so far, hence
  // by UINT32_MAX, even when a wide divisor multiple exceeds 32 bits.
  logic [31:0] trial_q;
  logic [15:1] fits;
  logic [35:0] candidate [0:15], pair_result [0:7], quartet [0:3];
  assign candidate[0] = {4'd0, trial_q};
  for (genvar k = 1; k < 8; k++) begin : gen_low
    wire borrow;
    wire [31:0] difference;
    assign {borrow, difference} = {1'b0, trial_q} - {1'b0, multiple[k][31:0]};
    assign fits[k] = !borrow && multiple[k][34:32] == 0;
    assign candidate[k] = {4'(k), difference};
  end
  for (genvar k = 8; k < 16; k++) begin : gen_upper
    // Only radix 16 can select here. T < 16D < 2^21 and R < 2^17.
    wire [16:0] difference = trial_q[16:0] - upper[k][16:0];
    assign fits[k] = trial_q[20:0] >= upper[k];
    assign candidate[k] = {4'(k), 15'b0, difference};
  end
  for (genvar p = 0; p < 8; p++) begin : gen_pair
    assign pair_result[p] = fits[2*p+1] ? candidate[2*p+1] : candidate[2*p];
  end
  for (genvar g = 0; g < 4; g++) begin : gen_quartet
    assign quartet[g] = fits[4*g+2] ? pair_result[2*g+1] : pair_result[2*g];
  end
  wire [35:0] low_half  = fits[4]  ? quartet[1] : quartet[0];
  wire [35:0] high_half = fits[12] ? quartet[3] : quartet[2];
  logic [3:0] digit;
  logic [31:0] digit_rem;
  assign {digit, digit_rem} = !radix8_q && fits[8] ? high_half : low_half;

  // Each nibble initially holds dividend bits. Replace each consumed
  // nibble with a quotient digit. Radix 8 uses three bits per nibble.
  logic [15:0] stream_q;
  always_ff @(posedge clock) begin
    if (phase_q == 3'd1) begin
      // The initial 17-bit (radix 8) or 12-bit (radix 16) remainder
      // is already below D. Include the first digit in the trial now.
      trial_q <= use_radix8 ? {12'b0, dividend_q[31:12]} : {16'b0, dividend_q[31:16]};
      stream_q <= use_radix8 ? {1'b0, dividend_q[11:9], 1'b0, dividend_q[8:6],
                               1'b0, dividend_q[5:3],  1'b0, dividend_q[2:0]}
                            : dividend_q[15:0];
    end else begin
      trial_q <= radix8_q ? {digit_rem[28:0], stream_q[14:12]}
                          : {11'b0, digit_rem[16:0], stream_q[15:12]};
      stream_q <= {stream_q[11:0], digit};
    end
  end
  wire [19:0] quotient = radix8_q ? {5'b0, stream_q[14:12], stream_q[10:8], stream_q[6:4],
                                     stream_q[2:0], digit[2:0]} : {stream_q, digit};

  // Phase 1 reads the reciprocal. Phases 2 and 3 form the quotient
  // estimate and multiply it back by D. The estimate is at most one
  // low, so the residual is in [0, 2D) and its low 13 bits are exact.
  (* syn_ramstyle = "block_ram" *) logic [31:0] reciprocal_rom [0:4095];
  initial begin
    for (int bank = 0; bank < 4; bank++) begin
      for (int i = 0; i < 1024; i++) begin
        if (bank == 0 && i == 0) reciprocal_rom[0] = 0;
        else reciprocal_rom[bank*1024+i] = 32'hffff_ffff / (bank*1024+i);
      end
    end
  end
  logic [31:0] reciprocal_q, estimate_q, incremented_q;
  logic [12:0] product_q, residual_q;
  logic [11:0] corrected_rem_q;
  logic [31:0] corrected_quot_q;
  wire [11:0] small_d = divisor_q[11:0];
  always_ff @(posedge clock) begin
    reciprocal_q <= reciprocal_rom[small_d];
    estimate_q   <= 32'((64'(dividend_q) * reciprocal_q) >> 32);
    product_q    <= estimate_q[12:0] * small_d;
    incremented_q <= estimate_q + 1'b1;
    residual_q   <= dividend_q[12:0] - product_q;
    corrected_quot_q <= residual_q >= {1'b0, small_d} ? incremented_q : estimate_q;
    corrected_rem_q <= residual_q >= {1'b0, small_d} ? residual_q[11:0] - small_d
                                                      : residual_q[11:0];
  end

  // The magnitude of INT_MIN fits unsigned. DIV by -1 therefore wraps
  // to INT_MIN on truncation to XLEN, with a zero remainder.
  logic [31:0] magnitude_q;
  always_ff @(posedge clock) begin
    if (phase_q == 3'd6) begin
      if (zero_q)       magnitude_q <= want_rem_q ? dividend_q : '1;
      else if (small_q) magnitude_q <= want_rem_q ? {20'b0, corrected_rem_q} : corrected_quot_q;
      else              magnitude_q <= want_rem_q ? digit_rem : {12'b0, quotient};
    end
  end
  assign div_result = (magnitude_q ^ {32{negate_q}}) + 32'(negate_q);
`endif

  wire [32:0] mul_lhs = {(op == ALU_MULH || op == ALU_MULHSU) && a[31], a};
  wire [32:0] mul_rhs = {op == ALU_MULH && b[31], b};
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

      ALU_MUL, ALU_MULH, ALU_MULHSU, ALU_MULHU:
        out = ENABLE_MUL ? multiply_result(op, mul_lhs, mul_rhs) : 32'b0;
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU: out = div_result;
      default:  out = 32'b0;
    endcase
  end

endmodule
