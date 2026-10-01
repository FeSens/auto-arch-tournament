// rtl/alu.sv
//
// RV32IM combinational ALU. The hardware multiplier is one shared signed
// 33x33 SystemVerilog `*` (MUL/MULH/MULHU/MULHSU differ only in the two
// operand extension bits). DIV/DIVU/REM/REMU are NOT computed here: the
// non-ALTOPS build leaves them at `default: out = 0` and ex_stage
// substitutes the result of the sequential `divider` module. Under
// RISCV_FORMAL_ALTOPS the (a-b)^const stand-ins stay in force so
// riscv-formal sees the same single-cycle behaviour as always.
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

  // One shared 33x33 signed multiply. The extension bit is the operand's
  // sign bit when that operand is signed for this op, else 0:
  //   MUL / MULHU : unsigned x unsigned (MUL reads only the low half, which
  //                 is identical for every signedness)
  //   MULHSU      : a signed, b unsigned
  //   MULH        : signed x signed
  // prod[65:64] are pure sign copies and unused; Verilator's UNUSEDSIGNAL
  // is silenced locally.
  logic        a_signed;
  logic        b_signed;
  logic [32:0] a_ext;
  logic [32:0] b_ext;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] prod;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    shamt = b[4:0];

    a_signed = (op == ALU_MULH) || (op == ALU_MULHSU);
    b_signed = (op == ALU_MULH);
    a_ext    = {a_signed & a[31], a};
    b_ext    = {b_signed & b[31], b};
    prod     = $signed(a_ext) * $signed(b_ext);

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
      // run the real arithmetic. DIV/DIVU/REM/REMU are handled by the
      // sequential divider outside the ALU (see ex_stage.sv) and fall
      // through to the default arm in that build.
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
      ALU_MUL:    out = prod[31:0];
      ALU_MULH,
      ALU_MULHU,
      ALU_MULHSU: out = prod[63:32];
`endif
      default:  out = 32'b0;
    endcase
  end

endmodule
