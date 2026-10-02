// rtl/alu.sv
//
// RV32IM fast ALU and shared clocked multiply/division interfaces.
// Only RV32I results are combinational.
//
// RV32IM division semantics (overridden from straight `signed /`):
//   DIV  by 0       -> -1   (all ones)
//   DIVU by 0       -> 0xFFFFFFFF
//   DIV  INT_MIN/-1 -> INT_MIN  (no trap, defined overflow)
//   REM  by 0       -> dividend
//   REMU by 0       -> dividend
//   REM  INT_MIN/-1 -> 0
//
// Latency:        fast output 0 cycles; M-extension completion is registered.
// RISCV_FORMAL_ALTOPS formulas live in the corresponding clocked unit,
// with the same operand capture and held completion as real arithmetic.
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
module alu (
  input  logic        clock,
  input  logic        reset,
  input  logic        div_request,
  input  logic        div_consume,
  input  logic        mul_request,
  input  logic        mul_consume,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out,
  output logic        div_busy,
  output logic        div_done,
  output logic [31:0] div_result,
  output logic        mul_busy,
  output logic        mul_done,
  output logic [31:0] mul_result
);

  divider u_divider (
    .clock(clock), .reset(reset), .request(div_request),
    .consume(div_consume), .op(op), .a(a), .b(b),
    .busy(div_busy), .done(div_done), .result(div_result)
  );

  multiplier u_multiplier (
    .clock(clock), .reset(reset), .request(mul_request),
    .consume(mul_consume), .op(op), .a(a), .b(b),
    .busy(mul_busy), .done(mul_done), .result(mul_result)
  );

  logic        [4:0]  shamt;

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

      default:  out = 32'b0;
    endcase
  end

endmodule
