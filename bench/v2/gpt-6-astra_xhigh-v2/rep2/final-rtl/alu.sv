// rtl/alu.sv
//
// RV32IM ALU: combinational base operations and separate blocking multiply
// and divide interfaces. Captured operands hold completion under backpressure.
//
// RV32IM division semantics (overridden from straight `signed /`):
//   DIV  by 0       -> -1   (all ones)
//   DIVU by 0       -> 0xFFFFFFFF
//   DIV  INT_MIN/-1 -> INT_MIN  (no trap, defined overflow)
//   REM  by 0       -> dividend
//   REMU by 0       -> dividend
//   REM  INT_MIN/-1 -> 0
//
// Latency:        base: combinational; multiply: capture at edge one, transfer
//                 at edge two; divide: earliest transfer at edge nine.
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module alu (
  input  logic        clock,
  input  logic        reset,
  input  logic        mul_req_valid,
  output logic        mul_req_ready,
  output logic        mul_result_valid,
  input  logic        mul_result_ready,
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
  divider u_divider (
    .clock(clock), .reset(reset),
    .req_valid(div_req_valid), .req_ready(div_req_ready),
    .op(op), .a(a), .b(b),
    .result_valid(div_result_valid), .result_ready(div_result_ready),
    .result(div_result)
  );

  logic mul_pending_q;
  logic [31:0] mul_a_q, mul_b_q, mul_result;
`ifdef RISCV_FORMAL_ALTOPS
  logic [4:0] mul_op_q;
`else
  logic mul_sign_a_q, mul_sign_b_q, mul_low_q;
`endif
  assign mul_req_ready = !mul_pending_q;
  assign mul_result_valid = mul_pending_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      mul_pending_q <= 1'b0;
      mul_a_q <= '0;
      mul_b_q <= '0;
`ifdef RISCV_FORMAL_ALTOPS
      mul_op_q <= '0;
`else
      mul_sign_a_q <= 1'b0;
      mul_sign_b_q <= 1'b0;
      mul_low_q <= 1'b0;
`endif
    end else if (mul_pending_q) begin
      if (mul_result_ready) mul_pending_q <= 1'b0;
    end else if (mul_req_valid) begin
      mul_pending_q <= 1'b1;
      mul_a_q <= a;
      mul_b_q <= b;
`ifdef RISCV_FORMAL_ALTOPS
      mul_op_q <= op;
`else
      mul_sign_a_q <= (op == ALU_MULH || op == ALU_MULHSU) && a[31];
      mul_sign_b_q <= (op == ALU_MULH) && b[31];
      mul_low_q <= (op == ALU_MUL);
`endif
    end
  end

`ifdef RISCV_FORMAL_ALTOPS
  always_comb begin
    case (mul_op_q)
      ALU_MUL:    mul_result = (mul_a_q + mul_b_q) ^ 32'h5876063e;
      ALU_MULH:   mul_result = (mul_a_q + mul_b_q) ^ 32'hf6583fb7;
      ALU_MULHU:  mul_result = (mul_a_q + mul_b_q) ^ 32'h949ce5e8;
      ALU_MULHSU: mul_result = (mul_a_q - mul_b_q) ^ 32'hecfbe137;
      default:    mul_result = '0;
    endcase
  end
`else
  // Sign bits and product selection are captured with the operands, leaving
  // no operation decode before the DSP. EX/MEM alone registers the product.
  logic signed [32:0] mul_a, mul_b;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] mul_product;
  /* verilator lint_on UNUSEDSIGNAL */
  assign mul_a = $signed({mul_sign_a_q, mul_a_q});
  assign mul_b = $signed({mul_sign_b_q, mul_b_q});
  assign mul_product = mul_a * mul_b;
  assign mul_result = mul_low_q ? mul_product[31:0] : mul_product[63:32];
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
      ALU_MUL, ALU_MULH, ALU_MULHU, ALU_MULHSU: out = mul_result;
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU: out = div_result;
      default:  out = 32'b0;
    endcase
  end

endmodule
