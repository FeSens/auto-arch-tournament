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

  // Single RV32M product. The extra operand bit is selected per multiply
  // variant: zero/zero for MUL and MULHU, sign/sign for MULH, and
  // sign/zero for MULHSU. MUL uses zero extension because the low 32 bits
  // are identical for signed and unsigned multiplication.
  logic signed [32:0] mul_a;
  logic signed [32:0] mul_b;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] mul_product;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    shamt = b[4:0];

    case (op)
      ALU_MULH, ALU_MULHSU: mul_a = {a[31], a};
      default:              mul_a = {1'b0,  a};
    endcase

    case (op)
      ALU_MULH: mul_b = {b[31], b};
      default:  mul_b = {1'b0,  b};
    endcase

    mul_product = mul_a * mul_b;

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
      ALU_MUL:    out = $unsigned(mul_product[31:0]);
      ALU_MULH:   out = $unsigned(mul_product[63:32]);
      ALU_MULHU:  out = $unsigned(mul_product[63:32]);
      ALU_MULHSU: out = $unsigned(mul_product[63:32]);
      ALU_DIV: begin
        if (b == 32'b0)
          out = 32'hFFFFFFFF;
        else if (a == 32'h80000000 && b == 32'hFFFFFFFF)
          out = 32'h80000000;
        else
          out = $unsigned($signed(a) / $signed(b));
      end
      ALU_DIVU: out = (b == 32'b0) ? 32'hFFFFFFFF : (a / b);
      ALU_REM: begin
        if (b == 32'b0)
          out = a;
        else if (a == 32'h80000000 && b == 32'hFFFFFFFF)
          out = 32'b0;
        else
          out = $unsigned($signed(a) % $signed(b));
      end
      ALU_REMU: out = (b == 32'b0) ? a : (a % b);
`endif
      default:  out = 32'b0;
    endcase
  end

endmodule
