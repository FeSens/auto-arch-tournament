// rtl/alu.sv
//
// RV32I + RV32M-multiply combinational ALU. DIV/DIVU/REM/REMU are NOT
// computed here — they run in the iterative rtl/div_unit.sv, and this ALU
// drives 0 for those ops (the EX stage ORs the divider's result in).
//
// Multiply: one signed 33x33 product whose operands are sign- or
// zero-extended per op, so a single MULT36X36 covers all four variants:
//   MUL    : a zero-ext, b zero-ext -> product[31:0]
//   MULH   : a sign-ext, b sign-ext -> product[63:32]
//   MULHU  : a zero-ext, b zero-ext -> product[63:32]
//   MULHSU : a sign-ext, b zero-ext -> product[63:32]
// (MUL's low half is the same for every extension choice.)
//
// Result select is two-level: the simple integer result and the multiply
// result are formed independently, then one mux picks between them.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
module alu (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  logic [4:0]  shamt;
  logic [31:0] simple_out;
  logic [31:0] mul_out;
  logic        is_mul;

`ifndef RISCV_FORMAL_ALTOPS
  logic               a_sext;
  logic               b_sext;
  logic signed [32:0] mul_a;
  logic signed [32:0] mul_b;
  logic        [63:0] mul_p;
`endif

  always_comb begin
    shamt = b[4:0];

    case (op)
      ALU_ADD:    simple_out = a + b;
      ALU_SUB:    simple_out = a - b;
      ALU_AND:    simple_out = a & b;
      ALU_OR:     simple_out = a | b;
      ALU_XOR:    simple_out = a ^ b;
      ALU_SLT:    simple_out = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU:   simple_out = {31'b0, a < b};
      ALU_SLL:    simple_out = a << shamt;
      ALU_SRL:    simple_out = a >> shamt;
      ALU_SRA:    simple_out = $unsigned($signed(a) >>> shamt);
      ALU_LUI:    simple_out = b;
      default:    simple_out = 32'b0;
    endcase

    is_mul = (op == ALU_MUL) || (op == ALU_MULH) ||
             (op == ALU_MULHU) || (op == ALU_MULHSU);

    // Under RISCV_FORMAL_ALTOPS the hardware multiply is substituted for
    // tractable algebraic stand-ins so bitwuzla can solve the BMC inside
    // the 20-step depth budget. The same substitution must appear in the
    // riscv-formal spec (insn_*.v). The Verilator/cocotb/cosim builds
    // leave ALTOPS undefined and run the real arithmetic.
`ifdef RISCV_FORMAL_ALTOPS
    case (op)
      ALU_MUL:    mul_out = (a + b) ^ 32'h5876063e;
      ALU_MULH:   mul_out = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  mul_out = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: mul_out = (a - b) ^ 32'hecfbe137;
      default:    mul_out = 32'b0;
    endcase
`else
    a_sext = (op == ALU_MULH) || (op == ALU_MULHSU);
    b_sext = (op == ALU_MULH);
    mul_a  = $signed({a_sext & a[31], a});
    mul_b  = $signed({b_sext & b[31], b});
    // Both operands are signed 33-bit; the 64-bit assignment context
    // sign-extends them (no $unsigned() wrapper: that would make the
    // product self-determined, i.e. 33 bits), and the low 64 bits of the
    // product are exact for every variant.
    /* verilator lint_off WIDTHEXPAND */
    mul_p  = mul_a * mul_b;
    /* verilator lint_on WIDTHEXPAND */
    mul_out = (op == ALU_MUL) ? mul_p[31:0] : mul_p[63:32];
`endif

    out = is_mul ? mul_out : simple_out;
  end

endmodule
