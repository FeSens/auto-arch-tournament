// rtl/alu.sv
//
// RV32IM combinational ALU. Real MUL/MULH/MULHU/MULHSU and DIV/REM arithmetic
// is intentionally outside this module: ex_stage routes those operations
// through sidecar units. Under RISCV_FORMAL_ALTOPS the formal substitute
// formulas remain here to match riscv-formal's ALTOPS spec.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB) and branch resolution.
module alu (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
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

      // M-extension. Under RISCV_FORMAL_ALTOPS the hardware operations
      // are substituted for tractable algebraic stand-ins so bitwuzla
      // can solve the BMC inside the 20-step depth budget. The same
      // substitution must appear in the riscv-formal spec (insn_*.v).
      // The Verilator/cocotb/cosim builds leave ALTOPS undefined; all real
      // M-extension arithmetic is supplied by sidecars through ex_stage.
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
      ALU_MUL:    out = 32'b0;
      ALU_MULH:   out = 32'b0;
      ALU_MULHU:  out = 32'b0;
      ALU_MULHSU: out = 32'b0;
      ALU_DIV:    out = 32'b0;
      ALU_DIVU:   out = 32'b0;
      ALU_REM:    out = 32'b0;
      ALU_REMU:   out = 32'b0;
`endif
      default:  out = 32'b0;
    endcase
  end

endmodule
