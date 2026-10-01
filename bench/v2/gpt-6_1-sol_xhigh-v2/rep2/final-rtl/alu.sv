// rtl/alu.sv
//
// RV32IM ALU. Integer operations remain combinational. Multiplication and
// division each use a blocking registered request/response unit.
//
// RV32IM division semantics implemented by the clocked divider:
//   DIV  by 0       -> -1   (all ones)
//   DIVU by 0       -> 0xFFFFFFFF
//   DIV  INT_MIN/-1 -> INT_MIN  (no trap, defined overflow)
//   REM  by 0       -> dividend
//   REMU by 0       -> dividend
//   REM  INT_MIN/-1 -> 0
//
// Latency:        division capture + seven iterations + response transfer.
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module alu (
  input  logic        clock,
  input  logic        reset,
  input  logic        div_req_valid,
  output logic        div_req_ready,
  output logic        div_rsp_valid,
  input  logic        div_rsp_ready,
  input  logic        mul_req_valid,
  output logic        mul_req_ready,
  output logic        mul_rsp_valid,
  input  logic        mul_rsp_ready,
  output logic [31:0] mul_result,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  logic        [4:0]  shamt;
  logic [31:0] div_result;

  // Two-bit leaves fit LUT4s. At every level, 2*j+1 is the more
  // significant range: L = L_H | (E_H & L_K), E = E_H & E_K.
  logic [15:0] cmp_eq_leaf, cmp_lt_leaf;
  logic [7:0] cmp_eq_l1, cmp_lt_l1;
  logic [3:0] cmp_eq_l2, cmp_lt_l2;
  logic [1:0] cmp_eq_l3, cmp_lt_l3;
  /* verilator lint_off UNUSEDSIGNAL */
  logic cmp_equal;
  /* verilator lint_on UNUSEDSIGNAL */
  logic cmp_unsigned_lt, cmp_signed_lt;

  for (genvar j = 0; j < 16; j++) begin : cmp_leaves
    assign cmp_eq_leaf[j] = (a[2*j +: 2] == b[2*j +: 2]);
    assign cmp_lt_leaf[j] = (a[2*j +: 2] < b[2*j +: 2]);
  end
  for (genvar j = 0; j < 8; j++) begin : cmp_level1
    assign cmp_eq_l1[j] = cmp_eq_leaf[2*j+1] & cmp_eq_leaf[2*j];
    assign cmp_lt_l1[j] = cmp_lt_leaf[2*j+1] |
                         (cmp_eq_leaf[2*j+1] & cmp_lt_leaf[2*j]);
  end
  for (genvar j = 0; j < 4; j++) begin : cmp_level2
    assign cmp_eq_l2[j] = cmp_eq_l1[2*j+1] & cmp_eq_l1[2*j];
    assign cmp_lt_l2[j] = cmp_lt_l1[2*j+1] |
                         (cmp_eq_l1[2*j+1] & cmp_lt_l1[2*j]);
  end
  for (genvar j = 0; j < 2; j++) begin : cmp_level3
    assign cmp_eq_l3[j] = cmp_eq_l2[2*j+1] & cmp_eq_l2[2*j];
    assign cmp_lt_l3[j] = cmp_lt_l2[2*j+1] |
                         (cmp_eq_l2[2*j+1] & cmp_lt_l2[2*j]);
  end
  assign cmp_equal = cmp_eq_l3[1] & cmp_eq_l3[0];
  assign cmp_unsigned_lt = cmp_lt_l3[1] | (cmp_eq_l3[1] & cmp_lt_l3[0]);
  assign cmp_signed_lt = cmp_unsigned_lt ^ (a[31] ^ b[31]);

  divider u_divider (
    .clock(clock), .reset(reset),
    .req_valid(div_req_valid), .req_ready(div_req_ready),
    .op(op), .a(a), .b(b),
    .rsp_valid(div_rsp_valid), .rsp_ready(div_rsp_ready),
    .result(div_result)
  );

  multiplier u_multiplier (
    .clock(clock), .reset(reset),
    .req_valid(mul_req_valid), .req_ready(mul_req_ready),
    .op(op), .a(a), .b(b),
    .rsp_valid(mul_rsp_valid), .rsp_ready(mul_rsp_ready),
    .result(mul_result)
  );

  always_comb begin
    shamt = b[4:0];

    case (op)
      ALU_ADD:    out = a + b;
      ALU_SUB:    out = a - b;
      ALU_AND:    out = a & b;
      ALU_OR:     out = a | b;
      ALU_XOR:    out = a ^ b;
      ALU_SLT:    out = {31'b0, cmp_signed_lt};
      ALU_SLTU:   out = {31'b0, cmp_unsigned_lt};
      ALU_SLL:    out = a << shamt;
      ALU_SRL:    out = a >> shamt;
      ALU_SRA:    out = $unsigned($signed(a) >>> shamt);
      ALU_LUI:    out = b;

      // MUL responses transfer directly into EX/MEM, outside this mux.
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU:
        out = div_result;
      default:  out = 32'b0;
    endcase
  end

endmodule
