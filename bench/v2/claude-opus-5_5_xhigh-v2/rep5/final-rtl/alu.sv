// rtl/alu.sv
//
// RV32IM combinational ALU (everything except DIV/DIVU/REM/REMU, which
// run in the multi-cycle div_unit). The multiplier is a single signed
// 33x33 SystemVerilog `*`.
//
// The MUL selects (mul_sel, mul_hi, operand signedness) arrive as
// registered bits from ID/EX, so the product meets one flop-selected
// 2-level mux at the output while the non-MUL op tree (plus the
// div_unit result OR) runs in parallel with the multiplier.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
module alu (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        mul_sel,       // op is MUL/MULH/MULHU/MULHSU
  /* verilator lint_off UNUSEDSIGNAL */  // unused under ALTOPS
  input  logic        mul_hi,        // op is MULH/MULHU/MULHSU (p[63:32])
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic        mul_a_signed,  // MULH, MULHSU
  input  logic        mul_b_signed,  // MULH
  input  logic [31:0] div_in,        // div_unit result (0 unless DONE)
  output logic [31:0] out
);

  logic        [4:0]  shamt;
  logic        [31:0] nonmul;
  logic        [31:0] mul_out;

  // One signed 33x33 product serves all four MUL ops: the 33rd operand bit
  // is the sign bit for signed operands and 0 for unsigned ones. MUL reads
  // p[31:0] (identical for every signedness), MULH/MULHSU/MULHU read
  // p[63:32]. p[65:64] are pure sign extension and unused.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] mul_p;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    shamt = b[4:0];

    mul_p = $signed({a[31] & mul_a_signed, a}) *
            $signed({b[31] & mul_b_signed, b});

    // M-extension. Under RISCV_FORMAL_ALTOPS the hardware operations
    // are substituted for tractable algebraic stand-ins so bitwuzla
    // can solve the BMC inside the 20-step depth budget. The same
    // substitution must appear in the riscv-formal spec (insn_*.v).
    // The Verilator/cocotb/cosim builds leave ALTOPS undefined and
    // run the real arithmetic.
`ifdef RISCV_FORMAL_ALTOPS
    case (op)
      ALU_MULH:   mul_out = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  mul_out = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: mul_out = (a - b) ^ 32'hecfbe137;
      default:    mul_out = (a + b) ^ 32'h5876063e;  // ALU_MUL
    endcase
`else
    mul_out = mul_hi ? mul_p[63:32] : mul_p[31:0];
`endif

    case (op)
      ALU_ADD:    nonmul = a + b;
      ALU_SUB:    nonmul = a - b;
      ALU_AND:    nonmul = a & b;
      ALU_OR:     nonmul = a | b;
      ALU_XOR:    nonmul = a ^ b;
      ALU_SLT:    nonmul = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU:   nonmul = {31'b0, a < b};
      ALU_SLL:    nonmul = a << shamt;
      ALU_SRL:    nonmul = a >> shamt;
      ALU_SRA:    nonmul = $unsigned($signed(a) >>> shamt);
      ALU_LUI:    nonmul = b;
      // MUL* take the mul_out slot below. DIV/DIVU/REM/REMU (and their
      // ALTOPS forms) live in div_unit.sv: they fall through to 0 here
      // and the divider result is ORed in (div_in is 0 unless DONE).
      default:    nonmul = 32'b0;
    endcase

    out = mul_sel ? mul_out : (nonmul | div_in);
  end

endmodule
