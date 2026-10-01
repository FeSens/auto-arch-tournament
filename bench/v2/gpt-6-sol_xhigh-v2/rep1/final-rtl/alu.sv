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
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB); memory addresses use the
//                 separate EX effective-address adder.
module alu #(
  // Core EX uses its iterative divider; direct ALU tests retain the
  // combinational RV32M behavior by default.
  parameter bit COMB_DIV = 1'b1,
  // The core registers raw products in EX/MEM and selects them in MEM.
  // Standalone ALU users retain the complete combinational behavior.
  parameter bit COMB_MUL = 1'b1
) (
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

  generate if (COMB_MUL) begin : g_comb_mul
    assign mul_ss = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
    assign mul_uu = {32'b0, a} * {32'b0, b};
    assign mul_su = $signed({{32{a[31]}}, a}) * $signed({32'b0, b});
  end else begin : g_no_comb_mul
    assign mul_ss = '0;
    assign mul_uu = '0;
    assign mul_su = '0;
  end endgenerate

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
      ALU_DIV:    out = (a - b) ^ 32'h7f8529ec;
      ALU_DIVU:   out = (a - b) ^ 32'h10e8fd70;
      ALU_REM:    out = (a - b) ^ 32'h8da68fa5;
      ALU_REMU:   out = (a - b) ^ 32'h3138d0e1;
`else
      ALU_MUL:    out = mul_uu[31:0];
      ALU_MULH:   out = $unsigned(mul_ss[63:32]);
      ALU_MULHU:  out = mul_uu[63:32];
      ALU_MULHSU: out = $unsigned(mul_su[63:32]);
      ALU_DIV: begin
        if (!COMB_DIV)
          out = 32'b0;
        else if (b == 32'b0)
          out = 32'hFFFFFFFF;
        else if (a == 32'h80000000 && b == 32'hFFFFFFFF)
          out = 32'h80000000;
        else
          out = $unsigned($signed(a) / $signed(b));
      end
      ALU_DIVU: out = !COMB_DIV ? 32'b0 :
                      (b == 32'b0) ? 32'hFFFFFFFF : (a / b);
      ALU_REM: begin
        if (!COMB_DIV)
          out = 32'b0;
        else if (b == 32'b0)
          out = a;
        else if (a == 32'h80000000 && b == 32'hFFFFFFFF)
          out = 32'b0;
        else
          out = $unsigned($signed(a) % $signed(b));
      end
      ALU_REMU: out = !COMB_DIV ? 32'b0 :
                      (b == 32'b0) ? a : (a % b);
`endif
      default:  out = 32'b0;
    endcase
  end

endmodule
