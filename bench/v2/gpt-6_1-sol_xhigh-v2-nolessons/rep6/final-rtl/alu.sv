// rtl/alu.sv
//
// RV32I combinational ALU. Real multiplication completes in MEM and
// DIV/REM executes in divider.sv; ALTOPS substitutes remain here. EX
// disables shifts so their captured operands complete only in MEM.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
module alu #(
  parameter bit ENABLE_SHIFTS = 1'b1
) (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  // Retained interface; multiplication now uses captured MEM operands.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] mul_rs1,
  input  logic [31:0] mul_rs2,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0] out
);

  logic [31:0] left_result, right_result;

  // SRL and SRA share the same five levels of data movement. Every
  // vacated bit uses the original operand's sign (SRA) or zero (SRL).
  generate
    if (ENABLE_SHIFTS) begin : g_shifts
      logic fill;
      logic [31:0] shift1, shift2, shift4, shift8;
      assign fill = (op == ALU_SRA) && a[31];
      assign shift1 = b[0] ? {fill, a[31:1]} : a;
      assign shift2 = b[1] ? {{2{fill}}, shift1[31:2]} : shift1;
      assign shift4 = b[2] ? {{4{fill}}, shift2[31:4]} : shift2;
      assign shift8 = b[3] ? {{8{fill}}, shift4[31:8]} : shift4;
      assign right_result = b[4] ? {{16{fill}}, shift8[31:16]} : shift8;
      assign left_result = a << b[4:0];
    end else begin : g_no_shifts
      assign left_result = 32'b0;
      assign right_result = 32'b0;
    end
  endgenerate

  always_comb begin
    case (op)
      ALU_ADD:    out = a + b;
      ALU_SUB:    out = a - b;
      ALU_AND:    out = a & b;
      ALU_OR:     out = a | b;
      ALU_XOR:    out = a ^ b;
      ALU_SLT:    out = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU:   out = {31'b0, a < b};
      ALU_SLL:    out = left_result;
      ALU_SRL, ALU_SRA: out = right_result;
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
      ALU_MUL, ALU_MULH, ALU_MULHU, ALU_MULHSU: out = 32'b0;
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU: out = 32'b0;
`endif
      default:  out = 32'b0;
    endcase
  end

endmodule
