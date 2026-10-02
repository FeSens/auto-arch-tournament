// rtl/alu.sv
//
// RV32IM combinational ALU. The hardware multiplier is the SystemVerilog
// `*` operator on signed types — Verilator and Yosys both support it and
// emit reasonable structural hardware.
//
// The MUL/MULH/MULHSU/MULHU family comes out on separate `p_lo` / `p_hi`
// ports (and `out` is 0 for those ops): ex_stage merges the product only at
// the EX/MEM.alu_result flop, so the multiplier is not part of the ex_res
// cone (P1 bypass source) that feeds the ID/EX flops. `p_lo` / `p_hi` are
// only meaningful when the instruction is one of the four multiply ops;
// ex_stage selects them with the decoder's pre-decoded mul_lo / mul_hi bits.
//
// One shared signed 33x33 multiplier serves all four ops. It reads the raw
// rs1/rs2 operands (`mul_a` / `mul_b`; MUL* never use the immediate or PC, so
// these are the same values as `a` / `b`, but they bypass any operand mux)
// and the pre-decoded `sgn_a` / `sgn_b` flags (no alu_op compare in front of
// the DSP): the operand extension bits are sgn_a & mul_a[31] and
// sgn_b & mul_b[31].
//   MUL    : low 32 bits (signedness irrelevant)
//   MULH   : signed   * signed,   high 32 bits
//   MULHSU : signed   * unsigned, high 32 bits
//   MULHU  : unsigned * unsigned, high 32 bits
//
// DIV/DIVU/REM/REMU are NOT implemented here (outside RISCV_FORMAL_ALTOPS):
// the iterative rtl/divider.sv executes them while ex_stage.sv stalls the
// pipeline, so these ops yield 0 from this module. (RV32M semantics
// implemented there: DIV/DIVU by 0 -> all ones, REM/REMU by 0 -> dividend,
// INT_MIN / -1 -> INT_MIN, INT_MIN % -1 -> 0.)
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution.
module alu (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  // Multiplier operands (raw rs1 / rs2) and pre-decoded signedness. Unused
  // under RISCV_FORMAL_ALTOPS, where the multiply stand-ins use a / b / op.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] mul_a,
  input  logic [31:0] mul_b,
  input  logic        sgn_a,
  input  logic        sgn_b,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0] out,
  output logic [31:0] p_lo,       // product[31:0]  (MUL)
  output logic [31:0] p_hi        // product[63:32] (MULH/MULHSU/MULHU)
);

  logic        [4:0]  shamt;

  // Shared signed 33x33 multiplier. Only the low 64 bits of the product are
  // needed (the full product of two 33-bit signed operands fits in 66 bits,
  // but the operands are 32-bit values plus one extension bit, so bits
  // [65:64] are a copy of bit 63). The operands are sign-extended to 64 bits
  // explicitly so every operator sees matching widths. Under
  // RISCV_FORMAL_ALTOPS the multiplier is unused and dead-code-eliminated.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [32:0] mul_xa;
  logic signed [32:0] mul_xb;
  logic signed [63:0] mul_p;
  logic        [31:0] mul_alt;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    shamt = b[4:0];

    mul_xa = {sgn_a & mul_a[31], mul_a};
    mul_xb = {sgn_b & mul_b[31], mul_b};
    mul_p  = $signed({{31{mul_xa[32]}}, mul_xa}) * $signed({{31{mul_xb[32]}}, mul_xb});

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
      // run the real arithmetic. The multiply stand-ins live on p_lo / p_hi
      // (below); `out` is 0 for MUL/MULH/MULHU/MULHSU.
`ifdef RISCV_FORMAL_ALTOPS
      ALU_DIV:    out = (a - b) ^ 32'h7f8529ec;
      ALU_DIVU:   out = (a - b) ^ 32'h10e8fd70;
      ALU_REM:    out = (a - b) ^ 32'h8da68fa5;
      ALU_REMU:   out = (a - b) ^ 32'h3138d0e1;
`endif
      // Real DIV/DIVU/REM/REMU are executed by rtl/divider.sv (iterative,
      // stalls EX); they fall to `default: out = 0` here.
      default:  out = 32'b0;
    endcase

    // Late (multiplier-family) result. Don't-care for non-multiply ops.
`ifdef RISCV_FORMAL_ALTOPS
    case (op)
      ALU_MUL:    mul_alt = (a + b) ^ 32'h5876063e;
      ALU_MULH:   mul_alt = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  mul_alt = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: mul_alt = (a - b) ^ 32'hecfbe137;
      default:    mul_alt = 32'b0;
    endcase
    p_lo = mul_alt;
    p_hi = mul_alt;
`else
    mul_alt = 32'b0;
    p_lo    = mul_p[31:0];
    p_hi    = mul_p[63:32];
`endif
  end

endmodule
