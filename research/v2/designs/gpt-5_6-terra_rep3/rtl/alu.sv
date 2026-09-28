// rtl/alu.sv
//
// RV32IM combinational ALU. Hardware multiplier and divider are SystemVerilog
// `*` and `/` on signed/unsigned types — Verilator and Yosys both support
// these and emit reasonable structural hardware.
//
// RV32IM division semantics (overridden from straight `signed /`):
//   DIV  by 0       -> -1   (all ones)
//   DIVU by 0       -> 0xFFFFFFFF
//   DIV  INT_MIN/-1 -> INT_MIN  (no trap, defined overflow)
//   REM  by 0       -> dividend
//   REMU by 0       -> dividend
//   REM  INT_MIN/-1 -> 0
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
module alu (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  logic        [4:0]  shamt;

  // 64-bit products, computed once and selected per op.
  // mul_ss/mul_su low halves are unused (only MULH/MULHSU read the high
  // half). Verilator's UNUSEDSIGNAL is silenced locally — the unused
  // bits are dead-code-eliminated by Yosys.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [63:0] mul_ss;  // signed*signed
  logic        [63:0] mul_uu;  // unsigned*unsigned (both halves used)
  logic signed [63:0] mul_su;  // signed*unsigned (a signed, b unsigned)
  /* verilator lint_on UNUSEDSIGNAL */

  // DIV/DIVU/REM/REMU share one unsigned magnitude datapath.  Signed
  // operations convert both operands to magnitudes before the divide, then
  // restore the quotient sign (sign(a) ^ sign(b)) or remainder sign
  // (sign(a)).  Two's-complement negation naturally preserves INT_MIN as
  // 0x80000000, including the mandated INT_MIN / -1 result.
  logic        div_signed_op;
  logic        div_quotient_negative;
  logic        div_remainder_negative;
  logic [31:0] div_a_magnitude;
  logic [31:0] div_b_magnitude;
  logic [31:0] div_quotient_magnitude;
  logic [31:0] div_remainder_magnitude;

  always_comb begin
    shamt = b[4:0];

    mul_ss = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
    mul_uu = {32'b0, a} * {32'b0, b};
    mul_su = $signed({{32{a[31]}}, a}) * $signed({32'b0, b});

    div_signed_op         = (op == ALU_DIV) || (op == ALU_REM);
    div_a_magnitude       = a;
    div_b_magnitude       = b;
    if (div_signed_op) begin
      if (a[31]) div_a_magnitude = (~a) + 32'd1;
      if (b[31]) div_b_magnitude = (~b) + 32'd1;
    end
    div_quotient_negative = div_signed_op && (a[31] != b[31]);
    div_remainder_negative = div_signed_op && a[31];

    // Keep the zero-divisor behavior out of the operators.  The operation
    // case below supplies RV32M's architecturally defined zero-divisor
    // values, while this one quotient/remainder pair handles every nonzero
    // divisor across all four operations.
    div_quotient_magnitude  = 32'b0;
    div_remainder_magnitude = 32'b0;
    if (div_b_magnitude != 32'b0) begin
      div_quotient_magnitude  = div_a_magnitude / div_b_magnitude;
      div_remainder_magnitude = div_a_magnitude % div_b_magnitude;
    end

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

      // M-extension. Under RISCV_FORMAL_ALTOPS the hardware operations
      // are substituted for tractable algebraic stand-ins so bitwuzla
      // can solve the BMC inside the 20-step depth budget. The same
      // substitution must appear in the riscv-formal spec (insn_*.v).
      // The Verilator/cocotb/cosim builds leave ALTOPS undefined and
      // run the real arithmetic.
`ifdef RISCV_FORMAL_ALTOPS
      ALU_MUL:    out = (a + b) ^ 32'h5876063e;
      ALU_MULH:   out = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  out = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: out = (a - b) ^ 32'hecfbe137;
      ALU_DIV:    out = (a - b) ^ 32'h7f8529ec;
      ALU_DIVU:   out = (a - b) ^ 32'h10e8fd70;
      ALU_REM:    out = (a - b) ^ 32'h8da68fa5;
      ALU_REMU:   out = (a - b) ^ 32'h3138d0e1;
`else
      ALU_MUL:    out = mul_uu[31:0];
      ALU_MULH:   out = $unsigned(mul_ss[63:32]);
      ALU_MULHU:  out = mul_uu[63:32];
      ALU_MULHSU: out = $unsigned(mul_su[63:32]);
      ALU_DIV, ALU_DIVU:
        out = (b == 32'b0) ? 32'hFFFFFFFF
            : div_quotient_negative ? ((~div_quotient_magnitude) + 32'd1)
                                    : div_quotient_magnitude;
      ALU_REM, ALU_REMU:
        out = (b == 32'b0) ? a
            : div_remainder_negative ? ((~div_remainder_magnitude) + 32'd1)
                                     : div_remainder_magnitude;
`endif
      default:  out = 32'b0;
    endcase
  end

endmodule
