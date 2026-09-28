// rtl/alu.sv
//
// Fast RV32IM integer/multiply ALU with an independent blocking divider.
// Ordinary ALU operations and all four multiplies remain combinational.
// DIV/DIVU/REM/REMU use the retained, eight-edge div_unit handshake.
//
// Latency:        combinational except divide/remainder (8 edges).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module alu (
  input  logic        clock,
  input  logic        reset,
  input  logic        div_req_valid,
  output logic        div_req_ready,
  output logic        div_result_valid,
  input  logic        div_result_ready,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  logic        [4:0]  shamt;
  logic [31:0] div_result;

  div_unit u_div (
    .clock (clock), .reset (reset), .op (op), .a (a), .b (b),
    .req_valid (div_req_valid), .req_ready (div_req_ready),
    .result_valid (div_result_valid), .result_ready (div_result_ready),
    .result (div_result)
  );

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

    mul_ss = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
    mul_uu = {32'b0, a} * {32'b0, b};
    mul_su = $signed({{32{a[31]}}, a}) * $signed({32'b0, b});

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
      ALU_MUL:    out = mul_uu[31:0];
      ALU_MULH:   out = $unsigned(mul_ss[63:32]);
      ALU_MULHU:  out = mul_uu[63:32];
      ALU_MULHSU: out = $unsigned(mul_su[63:32]);
`endif
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU:
        out = div_result_valid ? div_result : 32'b0;
      default:  out = 32'b0;
    endcase
  end

endmodule
