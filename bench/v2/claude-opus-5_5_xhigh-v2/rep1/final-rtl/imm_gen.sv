// rtl/imm_gen.sv
//
// RV32I immediate generator. Sign-extends I/S/B/J immediates, zero-fills
// the low bits of U immediates.
//
// Decoded from instr[6:2] with don't-cares: the value is bit-exact for
// every opcode that uses an immediate (I: LOAD/OP-IMM/JALR/SYSTEM, S:
// STORE, B: BRANCH, U: LUI/AUIPC, J: JAL). Every other encoding (OP,
// MISC-MEM, reserved opcodes, instr[1:0] != 11) may produce any value:
// those either have alu_src = 0, no memory op and no redirect, or trap.
// The branch predictor's pc + imm target is gated by an exact JAL/BRANCH
// decode. Each type select below uses the fewest opcode bits that
// separate the immediate-using opcodes (op = instr[6:2]):
//   I 00000 00100 11001 11100 | S 01000 | B 11000 | U 01101 00101 | J 11011
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds the EX-stage immediate path (rd_wdata for ADDI,
//                 mem_addr for LOAD/STORE, pc_wdata for branches/jumps).
module imm_gen (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] instr,       // [1:0] are don't-care
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0] imm
);

  logic [4:0] op;
  logic       u, j, sb, b;

  always_comb begin
    op = instr[6:2];
    u  = op[2] && op[0];              // LUI, AUIPC
    j  = op[1];                       // JAL
    sb = op[3] && !op[2] && !op[0];   // STORE, BRANCH
    b  = sb && op[4];                 // BRANCH

    imm[31]    = instr[31];
    imm[30:20] = u        ? instr[30:20] : {11{instr[31]}};
    imm[19:12] = (u || j) ? instr[19:12] : {8{instr[31]}};
    imm[11]    = u ? 1'b0 : j ? instr[20] : b ? instr[7] : instr[31];
    imm[10:5]  = u ? 6'b0 : instr[30:25];
    imm[4:1]   = u ? 4'b0 : sb ? instr[11:8] : instr[24:21];
    imm[0]     = sb ? (!op[4] && instr[7]) : (!u && !j && instr[20]);
  end

endmodule
