// rtl/alu.sv
//
// RV32IM ALU. Base operations remain combinational. Both M groups use
// registered requests and sticky completion, independent of live bypasses.
//
// RV32IM division semantics (overridden from straight `signed /`):
//   DIV  by 0       -> -1   (all ones)
//   DIVU by 0       -> 0xFFFFFFFF
//   DIV  INT_MIN/-1 -> INT_MIN  (no trap, defined overflow)
//   REM  by 0       -> dividend
//   REMU by 0       -> dividend
//   REM  INT_MIN/-1 -> 0
//
// Latency:        MUL completes on edge two, DIV/REM on edge eight.
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module alu (
  input  logic        clock,
  input  logic        reset,
  input  logic        mul_launch,
  input  logic        mul_consume,
  input  logic        div_launch,
  input  logic        div_consume,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out,
  output logic        mul_busy,
  output logic        mul_result_valid,
  output logic        div_busy,
  output logic        div_result_valid
);

  logic        [4:0]  shamt;
  logic [31:0] div_result;
  divider u_divider (
    .clock(clock), .reset(reset), .launch(div_launch), .consume(div_consume),
    .op(op), .a(a), .b(b), .busy(div_busy),
    .result_valid(div_result_valid), .result(div_result)
  );

  logic [31:0] mul_a_q, mul_b_q, mul_result_q, mul_selected;
  logic [4:0] mul_op_q;

  // 64-bit products, computed once and selected per op.
  // mul_ss/mul_su low halves are unused (only MULH/MULHSU read the high
  // half). Verilator's UNUSEDSIGNAL is silenced locally — the unused
  // bits are dead-code-eliminated by Yosys.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [63:0] mul_ss;  // signed*signed
  logic        [63:0] mul_uu;  // unsigned*unsigned (both halves used)
  logic signed [63:0] mul_su;  // signed*unsigned (a signed, b unsigned)
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    shamt = b[4:0];

    mul_ss = $signed({{32{mul_a_q[31]}}, mul_a_q}) *
             $signed({{32{mul_b_q[31]}}, mul_b_q});
    mul_uu = {32'b0, mul_a_q} * {32'b0, mul_b_q};
    mul_su = $signed({{32{mul_a_q[31]}}, mul_a_q}) *
             $signed({32'b0, mul_b_q});

    // The existing three product expressions retain their DSP inference.
    // Selection and ALTOPS use the accepted operation and raw operands.
    case (mul_op_q)
`ifdef RISCV_FORMAL_ALTOPS
      ALU_MUL:    mul_selected = (mul_a_q + mul_b_q) ^ 32'h5876063e;
      ALU_MULH:   mul_selected = (mul_a_q + mul_b_q) ^ 32'hf6583fb7;
      ALU_MULHU:  mul_selected = (mul_a_q + mul_b_q) ^ 32'h949ce5e8;
      ALU_MULHSU: mul_selected = (mul_a_q - mul_b_q) ^ 32'hecfbe137;
`else
      ALU_MUL:    mul_selected = mul_uu[31:0];
      ALU_MULH:   mul_selected = $unsigned(mul_ss[63:32]);
      ALU_MULHU:  mul_selected = mul_uu[63:32];
      ALU_MULHSU: mul_selected = $unsigned(mul_su[63:32]);
`endif
      default:    mul_selected = 32'b0;
    endcase

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
      ALU_MUL, ALU_MULH, ALU_MULHU, ALU_MULHSU: out = mul_result_q;
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU: out = div_result;
      default:  out = 32'b0;
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      mul_a_q <= 32'b0;
      mul_b_q <= 32'b0;
      mul_op_q <= ALU_MUL;
      mul_result_q <= 32'b0;
      mul_busy <= 1'b0;
      mul_result_valid <= 1'b0;
    end else begin
      if (mul_consume) mul_result_valid <= 1'b0;
      if (mul_launch && !mul_busy && (!mul_result_valid || mul_consume) &&
          (op == ALU_MUL || op == ALU_MULH || op == ALU_MULHU || op == ALU_MULHSU)) begin
        // Edge one: capture only. No live multiplier drives the ALU cone.
        mul_a_q <= a;
        mul_b_q <= b;
        mul_op_q <= op;
        mul_busy <= 1'b1;
        mul_result_valid <= 1'b0;
      end else if (mul_busy) begin
        // Edge two: register the architectural product, then hold it.
        mul_result_q <= mul_selected;
        mul_busy <= 1'b0;
        mul_result_valid <= 1'b1;
      end
    end
  end

endmodule
