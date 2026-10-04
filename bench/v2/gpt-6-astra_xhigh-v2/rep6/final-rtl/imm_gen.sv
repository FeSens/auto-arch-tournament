// rtl/imm_gen.sv
//
// RV32I immediate generator. Sign-extends I/S/B/J immediates, zero-fills
// the low bits of U immediates. Opcodes that don't carry an immediate
// (R-type, FENCE, etc.) emit 0.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds the EX-stage immediate path (rd_wdata for ADDI,
//                 mem_addr for LOAD/STORE, pc_wdata for branches/jumps).
module imm_gen (
  input  logic [31:0] instr,
  output logic [31:0] imm
);

  logic [6:0] opcode;

  always_comb begin
    opcode = instr[6:0];
    case (opcode)
      // I-type: LOAD, OP-IMM, JALR, SYSTEM.
      7'b0000011, 7'b0010011, 7'b1100111, 7'b1110011:
        imm = {{20{instr[31]}}, instr[31:20]};
      // S-type: STORE.
      7'b0100011:
        imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
      // B-type: BRANCH (bit 0 implicit zero).
      7'b1100011:
        imm = {{19{instr[31]}}, instr[31], instr[7],
               instr[30:25], instr[11:8], 1'b0};
      // U-type: LUI, AUIPC (low 12 bits zero).
      7'b0110111, 7'b0010111:
        imm = {instr[31:12], 12'b0};
      // J-type: JAL (bit 0 implicit zero).
      7'b1101111:
        imm = {{11{instr[31]}}, instr[31], instr[19:12],
               instr[20], instr[30:21], 1'b0};
      default:
        imm = 32'b0;
    endcase
  end

endmodule
