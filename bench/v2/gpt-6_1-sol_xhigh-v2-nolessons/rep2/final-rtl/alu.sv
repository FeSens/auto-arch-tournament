// rtl/alu.sv
//
// RV32IM ALU: base arithmetic and multiplication remain combinational;
// division uses a shared clocked restoring unit with sticky completion.
//
// RV32IM division semantics (overridden from straight `signed /`):
//   DIV  by 0       -> -1   (all ones)
//   DIVU by 0       -> 0xFFFFFFFF
//   DIV  INT_MIN/-1 -> INT_MIN  (no trap, defined overflow)
//   REM  by 0       -> dividend
//   REMU by 0       -> dividend
//   REM  INT_MIN/-1 -> 0
//
// Latency:        combinational except DIV/DIVU/REM/REMU (bounded multi-cycle).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module alu (
  input  logic       clock,
  input  logic       reset,
  input  logic       div_start,
  input  logic       div_consume,
  output logic       div_busy,
  output logic       div_done,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  // Hardware-only formatted operands launch directly from ID/EX flops.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic signed [32:0] mul_a,
  input  logic signed [32:0] mul_b,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0] out
);

  logic        [4:0]  shamt;
  logic [31:0] div_result;
  divider u_divider (
    .clock(clock), .reset(reset), .start(div_start), .consume(div_consume),
    .op(op), .a(a), .b(b), .busy(div_busy), .done(div_done), .result(div_result)
  );

`ifndef RISCV_FORMAL_ALTOPS
  // A signed 33-bit operand represents both signed and unsigned RV32
  // values exactly. Share one native multiplier across all four variants.
  // Only the low 64 product bits are part of an RV32M result.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] mul_product;
  /* verilator lint_on UNUSEDSIGNAL */

  assign mul_product = mul_a * mul_b;
`endif

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
`else
      ALU_MUL:    out = mul_product[31:0];
      ALU_MULH:   out = mul_product[63:32];
      ALU_MULHU:  out = mul_product[63:32];
      ALU_MULHSU: out = mul_product[63:32];
`endif
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU:
                  out = div_done ? div_result : 32'b0;
      default:  out = 32'b0;
    endcase
  end

endmodule
