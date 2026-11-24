// rtl/alu.sv
//
// Combinational RV32I integer operations.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata via EX/MEM/WB.
module alu (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out,
  output logic [31:0] add_result,
  output logic [31:0] sub_result,
  output logic [31:0] other_result
);

  logic [4:0] shamt;
  logic signed [32:0] right_shift;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [32:0] shifted_right;
  /* verilator lint_on UNUSEDSIGNAL */
  assign shamt = b[4:0];
  assign right_shift = $signed({(op == ALU_SRA) && a[31], a});
  assign shifted_right = right_shift >>> shamt;

  assign add_result = a + b;
  assign sub_result = a - b;
  assign out = (op == ALU_ADD) ? add_result
             : (op == ALU_SUB) ? sub_result : other_result;

  always_comb begin
    case (op)
      ALU_AND:    other_result = a & b;
      ALU_OR:     other_result = a | b;
      ALU_XOR:    other_result = a ^ b;
      ALU_SLT:    other_result = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU:   other_result = {31'b0, a < b};
      ALU_SLL:    other_result = a << shamt;
      ALU_SRL, ALU_SRA: other_result = shifted_right[31:0];
      ALU_LUI:    other_result = b;

      default:    other_result = 32'b0;
    endcase
  end

endmodule
