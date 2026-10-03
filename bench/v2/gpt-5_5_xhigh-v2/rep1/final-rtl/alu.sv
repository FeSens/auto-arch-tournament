// rtl/alu.sv
//
// RV32IM combinational ALU. Hardware multiplier is still single-cycle here;
// DIV/REM are handled by mdiv_unit in ex_stage so ordinary ALU ops no longer
// share timing with a combinational divider.
//
// RV32IM division semantics (overridden from straight `signed /`):
//   DIV  by 0       -> -1   (all ones)
//   DIVU by 0       -> 0xFFFFFFFF
//   DIV  INT_MIN/-1 -> INT_MIN  (no trap, defined overflow)
//   REM  by 0       -> dividend
//   REMU by 0       -> dividend
//   REM  INT_MIN/-1 -> 0
//
// Latency:        combinational (0 cycles), except DIV/REM are external.
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
module alu (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  logic        [4:0]  shamt;

`ifndef RISCV_FORMAL_ALTOPS
  // Shared RV32M multiplier. Each operand gets one extra sign bit selected
  // from the active MUL* opcode, then a single signed 33x33 product feeds
  // the low and high half results.
  logic               mul_a_signed;
  logic               mul_b_signed;
  logic signed [32:0] mul_a_ext;
  logic signed [32:0] mul_b_ext;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] mul_product;  // [65:64] are above the RV32 result.
  /* verilator lint_on UNUSEDSIGNAL */
`endif

  always_comb begin
    shamt = b[4:0];

`ifndef RISCV_FORMAL_ALTOPS
    mul_a_signed = (op == ALU_MULH) || (op == ALU_MULHSU);
    mul_b_signed = (op == ALU_MULH);
    mul_a_ext    = $signed({mul_a_signed & a[31], a});
    mul_b_ext    = $signed({mul_b_signed & b[31], b});
    mul_product  = mul_a_ext * mul_b_ext;
`endif

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
      ALU_MUL:    out = mul_product[31:0];
      ALU_MULH:   out = $unsigned(mul_product[63:32]);
      ALU_MULHU:  out = $unsigned(mul_product[63:32]);
      ALU_MULHSU: out = $unsigned(mul_product[63:32]);
      // Real DIV/REM results come from the iterative mdiv_unit. Keep these
      // opcodes defined as benign values so accidental direct use is obvious
      // in tests without inferring a hardware divider on the ALU path.
      ALU_DIV,
      ALU_DIVU,
      ALU_REM,
      ALU_REMU:   out = 32'b0;
`endif
      default:  out = 32'b0;
    endcase
  end

endmodule
