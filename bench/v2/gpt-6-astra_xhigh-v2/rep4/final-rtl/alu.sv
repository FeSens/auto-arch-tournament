// rtl/alu.sv
//
// RV32IM ALU with a shared eight-iteration restoring divider. All other
// operations remain combinational. Division accepts one request, processes
// four dividend bits on each of eight iteration clocks, and
// holds completion until explicitly consumed.
//
// RV32IM division semantics (overridden from straight `signed /`):
//   DIV  by 0       -> -1   (all ones)
//   DIVU by 0       -> 0xFFFFFFFF
//   DIV  INT_MIN/-1 -> INT_MIN  (no trap, defined overflow)
//   REM  by 0       -> dividend
//   REMU by 0       -> dividend
//   REM  INT_MIN/-1 -> 0
//
// Latency:        divide: launch + eight iterations + consume; otherwise 0.
// RVFI fields:    feeds rd_wdata, with a separate divide completion output.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module alu #(
  parameter bit ENABLE_MULTIPLY = 1'b1
) (
  input  logic        clock,
  input  logic        reset,
  input  logic        div_request,
  input  logic        div_consume,
  output logic        div_busy,
  output logic        div_done,
  output logic [31:0] div_result,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  logic        [4:0]  shamt;

  logic [2:0] iteration;
`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result;
  assign div_result = alt_result;
`else
  logic [31:0] divisor_q, quotient_q, remainder_q;
  logic [31:0] dividend_q;
  logic quotient_negative, remainder_negative, select_remainder;
  logic divide_zero, signed_overflow;
  logic signed_operation;
  logic [31:0] dividend_magnitude, divisor_magnitude;
  logic [33:0] dwide, twice, triple_q;
  logic divisor_high_zero;
  logic [3:0] prefix_r [0:4];
  logic [3:0] prefix_q [0:4];
  logic [4:0] prefix_trial [0:3];
  logic [3:0] prefix_accept;
  logic [31:0] quotient_step [0:2];
  logic [31:0] remainder_step [0:2];
  logic [33:0] trial [0:1];
  logic [1:0] ge1, ge2, ge3, w0, w1, w2, w3;
  // Keep the full differences until their leading borrow bits are known.
  // The selected remainder fits in 32 bits (four bits for the prefix).
  /* verilator lint_off UNUSEDSIGNAL */
  logic [5:0] prefix_diff [0:3];
  logic [34:0] diff1 [0:1];
  logic [34:0] diff2 [0:1];
  logic [34:0] diff3 [0:1];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] magnitude_result;
  logic negate_result;

  assign signed_operation = op == ALU_DIV || op == ALU_REM;
  assign dividend_magnitude = (signed_operation && a[31]) ? (32'b0 - a) : a;
  assign divisor_magnitude = (signed_operation && b[31]) ? (32'b0 - b) : b;

  assign dwide = {2'b0, divisor_q};
  assign twice = dwide << 1;

  // On the first busy edge, consume the top nibble in narrow fabric while
  // preparing 3D from the registered divisor. No ROM or wide recurrence is
  // needed here: every partial dividend prefix is at most 15.
  assign divisor_high_zero = divisor_q[31:4] == 28'b0;
  assign prefix_r[0] = 4'b0;
  assign prefix_q[0] = quotient_q[31:28];
  for (genvar i = 0; i < 4; i++) begin : g_prefix_step
    assign prefix_trial[i] = {prefix_r[i], prefix_q[i][3]};
    assign prefix_diff[i] = {1'b0, prefix_trial[i]} - {2'b0, divisor_q[3:0]};
    assign prefix_accept[i] = !prefix_diff[i][5] && divisor_high_zero;
    assign prefix_r[i+1] = prefix_accept[i] ? prefix_diff[i][3:0]
                                          : prefix_trial[i][3:0];
    assign prefix_q[i+1] = {prefix_q[i][2:0], prefix_accept[i]};
  end

  // Each later busy edge consumes two radix-4 digits. The three trials
  // within each step are parallel; one-hot masks avoid a priority mux or
  // a second subtraction after digit selection.
  assign quotient_step[0] = quotient_q;
  assign remainder_step[0] = remainder_q;
  for (genvar i = 0; i < 2; i++) begin : g_divide_step
    assign trial[i] = {remainder_step[i], quotient_step[i][31:30]};
    assign diff1[i] = {1'b0, trial[i]} - {1'b0, dwide};
    assign diff2[i] = {1'b0, trial[i]} - {1'b0, twice};
    assign diff3[i] = {1'b0, trial[i]} - {1'b0, triple_q};
    assign ge1[i] = !diff1[i][34];
    assign ge2[i] = !diff2[i][34];
    assign ge3[i] = !diff3[i][34];
    assign w0[i] = !ge1[i];
    assign w1[i] = ge1[i] && !ge2[i];
    assign w2[i] = ge2[i] && !ge3[i];
    assign w3[i] = ge3[i];
    assign remainder_step[i+1] =
        (trial[i][31:0] & {32{w0[i]}}) | (diff1[i][31:0] & {32{w1[i]}})
      | (diff2[i][31:0] & {32{w2[i]}}) | (diff3[i][31:0] & {32{w3[i]}});
    assign quotient_step[i+1] = {quotient_step[i][29:0],
                                 w2[i] | w3[i], w1[i] | w3[i]};
  end

  always_comb begin
    magnitude_result = select_remainder ? remainder_q : quotient_q;
    negate_result = select_remainder ? remainder_negative : quotient_negative;
    div_result = negate_result ? (32'b0 - magnitude_result) : magnitude_result;
    if (divide_zero)
      div_result = select_remainder ? dividend_q : 32'hffffffff;
    else if (signed_overflow)
      div_result = select_remainder ? 32'b0 : 32'h80000000;
  end
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      div_busy <= 1'b0;
      div_done <= 1'b0;
      iteration <= 3'b0;
`ifdef RISCV_FORMAL_ALTOPS
      alt_result <= 32'b0;
`else
      divisor_q <= 32'b0;
      triple_q <= 34'b0;
      quotient_q <= 32'b0;
      remainder_q <= 32'b0;
      dividend_q <= 32'b0;
      quotient_negative <= 1'b0;
      remainder_negative <= 1'b0;
      select_remainder <= 1'b0;
      divide_zero <= 1'b0;
      signed_overflow <= 1'b0;
`endif
    end else if (div_busy) begin
`ifndef RISCV_FORMAL_ALTOPS
      // Four prefix bits plus seven groups of two radix-4 digits = 32 bits.
      if (iteration == 3'd0) begin
        triple_q <= (dwide << 1) + dwide;
        quotient_q <= {quotient_q[27:0], prefix_q[4]};
        remainder_q <= {28'b0, prefix_r[4]};
      end else begin
        quotient_q <= quotient_step[2];
        remainder_q <= remainder_step[2];
      end
`endif
      iteration <= iteration + 3'd1;
      if (iteration == 3'd7) begin
        div_busy <= 1'b0;
        div_done <= 1'b1;
      end
    end else if (div_done) begin
      if (div_consume) div_done <= 1'b0;
    end else if (div_request) begin
      div_busy <= 1'b1;
      iteration <= 3'b0;
`ifdef RISCV_FORMAL_ALTOPS
      case (op)
        ALU_DIV:  alt_result <= (a - b) ^ 32'h7f8529ec;
        ALU_DIVU: alt_result <= (a - b) ^ 32'h10e8fd70;
        ALU_REM:  alt_result <= (a - b) ^ 32'h8da68fa5;
        ALU_REMU: alt_result <= (a - b) ^ 32'h3138d0e1;
        default:  alt_result <= 32'b0;
      endcase
`else
      quotient_q <= dividend_magnitude;
      divisor_q <= divisor_magnitude;
      remainder_q <= 32'b0;
      dividend_q <= a;
      quotient_negative <= signed_operation && (a[31] ^ b[31]);
      remainder_negative <= signed_operation && a[31];
      select_remainder <= op == ALU_REM || op == ALU_REMU;
      divide_zero <= b == 32'b0;
      signed_overflow <= signed_operation && a == 32'h80000000
                         && b == 32'hffffffff;
`endif
    end
  end

  logic [31:0] mul_result;
  generate
    if (ENABLE_MULTIPLY) begin : g_multiply
      multiply u_multiply (.op(op), .a(a), .b(b), .out(mul_result));
    end else begin : g_no_multiply
      assign mul_result = 32'b0;
    end
  endgenerate

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

      ALU_MUL, ALU_MULH, ALU_MULHU, ALU_MULHSU: out = mul_result;
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU: out = div_result;
      default:  out = 32'b0;
    endcase
  end

endmodule

// Shared arithmetic definition for standalone ALU tests and MEM completion.
// The core instantiates this only after its EX/MEM operand registers.
/* verilator lint_off DECLFILENAME */
module multiply (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);
`ifndef RISCV_FORMAL_ALTOPS
  // Preserve the original full-width signed and unsigned product equations.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [63:0] mul_ss;
  logic        [63:0] mul_uu;
  logic signed [63:0] mul_su;
  /* verilator lint_on UNUSEDSIGNAL */
  assign mul_ss = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
  assign mul_uu = {32'b0, a} * {32'b0, b};
  assign mul_su = $signed({{32{a[31]}}, a}) * $signed({32'b0, b});
`endif

  always_comb begin
    case (op)
`ifdef RISCV_FORMAL_ALTOPS
      ALU_MUL:    out = (a + b) ^ 32'h5876063e;
      ALU_MULH:   out = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  out = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: out = (a - b) ^ 32'hecfbe137;
`else
      ALU_MUL:    out = mul_uu[31:0];
      ALU_MULH:   out = $unsigned(mul_ss[63:32]);
      ALU_MULHU:  out = mul_uu[63:32];
      ALU_MULHSU: out = $unsigned(mul_su[63:32]);
      // The caller owns multiply eligibility. A default low product avoids
      // decoding MUL twice, here and again at the completion boundary.
      default: out = mul_uu[31:0];
`endif
`ifdef RISCV_FORMAL_ALTOPS
      default: out = 32'b0;
`endif
    endcase
  end
endmodule
/* verilator lint_on DECLFILENAME */
