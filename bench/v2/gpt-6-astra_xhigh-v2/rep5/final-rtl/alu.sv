// rtl/alu.sv
//
// RV32IM combinational ALU. The standalone interface retains combinational
// multiplication/division for legacy arithmetic tests. The core statically
// disables both and executes M operations through registered units instead.
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
module alu #(
  parameter bit COMBINATIONAL_DIV = 1'b1,
  parameter bit COMBINATIONAL_MUL = 1'b1
) (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  logic        [4:0]  shamt;
  logic [31:0] div_result;
  logic [31:0] mul_result;

  // Only the standalone legacy ALU elaborates / and % operators. EX
  // disables this entire generate branch and uses div_unit instead.
  generate if (COMBINATIONAL_DIV) begin : g_div
    always_comb begin
      case (op)
`ifdef RISCV_FORMAL_ALTOPS
        ALU_DIV:  div_result = (a - b) ^ 32'h7f8529ec;
        ALU_DIVU: div_result = (a - b) ^ 32'h10e8fd70;
        ALU_REM:  div_result = (a - b) ^ 32'h8da68fa5;
        ALU_REMU: div_result = (a - b) ^ 32'h3138d0e1;
`else
        ALU_DIV: begin
          if (b == 0) div_result = 32'hffffffff;
          else if (a == 32'h80000000 && b == 32'hffffffff)
            div_result = 32'h80000000;
          else div_result = $unsigned($signed(a) / $signed(b));
        end
        ALU_DIVU: div_result = (b == 0) ? 32'hffffffff : (a / b);
        ALU_REM: begin
          if (b == 0) div_result = a;
          else if (a == 32'h80000000 && b == 32'hffffffff)
            div_result = 0;
          else div_result = $unsigned($signed(a) % $signed(b));
        end
        ALU_REMU: div_result = (b == 0) ? a : (a % b);
`endif
        default: div_result = 0;
      endcase
    end
  end else begin : g_no_div
    assign div_result = 32'b0;
  end endgenerate

  generate if (COMBINATIONAL_MUL) begin : g_mul
`ifndef RISCV_FORMAL_ALTOPS
  // 64-bit products, computed once and selected per op.
  // mul_ss/mul_su low halves are unused (only MULH/MULHSU read the high
  // half). Verilator's UNUSEDSIGNAL is silenced locally — the unused
  // bits are dead-code-eliminated by Yosys.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [63:0] mul_ss;  // signed*signed
  logic        [63:0] mul_uu;  // unsigned*unsigned (both halves used)
  logic signed [63:0] mul_su;  // signed*unsigned (a signed, b unsigned)
  /* verilator lint_on UNUSEDSIGNAL */
`endif
  always_comb begin
`ifndef RISCV_FORMAL_ALTOPS
    mul_ss = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
    mul_uu = {32'b0, a} * {32'b0, b};
    mul_su = $signed({{32{a[31]}}, a}) * $signed({32'b0, b});
`endif
    case (op)
`ifdef RISCV_FORMAL_ALTOPS
      ALU_MUL:    mul_result = (a + b) ^ 32'h5876063e;
      ALU_MULH:   mul_result = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  mul_result = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: mul_result = (a - b) ^ 32'hecfbe137;
`else
      ALU_MUL:    mul_result = mul_uu[31:0];
      ALU_MULH:   mul_result = $unsigned(mul_ss[63:32]);
      ALU_MULHU:  mul_result = mul_uu[63:32];
      ALU_MULHSU: mul_result = $unsigned(mul_su[63:32]);
`endif
      default: mul_result = '0;
    endcase
  end
  end else begin : g_no_mul
    assign mul_result = 32'b0;
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
      ALU_MUL, ALU_MULH, ALU_MULHU, ALU_MULHSU: out = mul_result;
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU: out = div_result;
      default:  out = 32'b0;
    endcase
  end

endmodule
