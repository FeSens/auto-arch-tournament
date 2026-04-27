// rtl/decoder.sv
//
// RV32IM instruction decoder. Maps a 32-bit instruction to control signals.
//
// Hard invariant (CLAUDE.md #2, #10):  is_illegal defaults to 1. It is
// cleared only inside arms that positively validate both opcode and the
// relevant funct fields (funct7 for R-type, funct3 for OP-IMM shifts,
// LOAD/STORE/BRANCH; full instruction match for SYSTEM/EBREAK).  Anything
// not explicitly recognised below traps via rvfi_trap.
//
// Convention (project-specific):
//   - EBREAK (0x00100073) is the *only* SYSTEM instruction marked legal.
//     ECALL, CSR ops, MRET all trap. EBREAK is the test-harness
//     termination marker; the architectural "should-trap" semantics are
//     intentionally relaxed here so selftest.S can halt without a CSR.
//   - FENCE / FENCE.I (opcode 0x0F) are architectural NOPs — legal but
//     reg_write=0, mem_*=0.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rvfi_trap (= is_illegal at retirement), and all
//                 control routing into EX/MEM/WB.
module decoder
  import core_pkg::*;
(
  input  logic [31:0] instr,
  output logic [4:0]  alu_op,
  output logic        alu_src,
  output logic [2:0]  branch_op,
  output logic        is_branch,
  output logic        is_jump,
  output logic        is_jalr,
  output logic        is_lui,
  output logic        is_auipc,
  output logic        mem_read,
  output logic        mem_write,
  output logic [1:0]  mem_width,
  output logic        mem_sext,
  output logic        reg_write,
  output logic        mem_to_reg,
  output logic        is_illegal
);

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;

  always_comb begin
    opcode = instr[6:0];
    funct3 = instr[14:12];
    funct7 = instr[31:25];

    // Defaults — note is_illegal = 1.
    alu_op     = ALU_ADD;
    alu_src    = 1'b0;
    branch_op  = BR_BEQ;
    is_branch  = 1'b0;
    is_jump    = 1'b0;
    is_jalr    = 1'b0;
    is_lui     = 1'b0;
    is_auipc   = 1'b0;
    mem_read   = 1'b0;
    mem_write  = 1'b0;
    mem_width  = 2'd2;
    mem_sext   = 1'b1;
    reg_write  = 1'b0;
    mem_to_reg = 1'b0;
    is_illegal = 1'b1;

    case (opcode)
      // ── R-type OP ───────────────────────────────────────────────────────
      7'b0110011: begin
        // funct7=0x00: every funct3 is a base RV32I R-op (ADD/SLL/SLT/...).
        // funct7=0x20: only funct3=0 (SUB) or funct3=5 (SRA).
        // funct7=0x01: M-extension, every funct3 valid.
        if (funct7 == 7'b0000000 ||
            (funct7 == 7'b0100000 && (funct3 == 3'd0 || funct3 == 3'd5)) ||
            funct7 == 7'b0000001) begin
          is_illegal = 1'b0;
          reg_write  = 1'b1;
          case ({funct7, funct3})
            10'b0000000_000: alu_op = ALU_ADD;
            10'b0100000_000: alu_op = ALU_SUB;
            10'b0000000_001: alu_op = ALU_SLL;
            10'b0000000_010: alu_op = ALU_SLT;
            10'b0000000_011: alu_op = ALU_SLTU;
            10'b0000000_100: alu_op = ALU_XOR;
            10'b0000000_101: alu_op = ALU_SRL;
            10'b0100000_101: alu_op = ALU_SRA;
            10'b0000000_110: alu_op = ALU_OR;
            10'b0000000_111: alu_op = ALU_AND;
            10'b0000001_000: alu_op = ALU_MUL;
            10'b0000001_001: alu_op = ALU_MULH;
            10'b0000001_010: alu_op = ALU_MULHSU;
            10'b0000001_011: alu_op = ALU_MULHU;
            10'b0000001_100: alu_op = ALU_DIV;
            10'b0000001_101: alu_op = ALU_DIVU;
            10'b0000001_110: alu_op = ALU_REM;
            10'b0000001_111: alu_op = ALU_REMU;
            default:         alu_op = ALU_ADD;
          endcase
        end
      end

      // ── I-type OP-IMM ───────────────────────────────────────────────────
      7'b0010011: begin
        // Non-shift funct3 (0,2,3,4,6,7) — funct7 bits are part of imm,
        // accept them all.
        // Shift funct3 (1 SLLI, 5 SRLI/SRAI) — funct7 must be 0x00 (or 0x20
        // for SRAI only).
        if (funct3 != 3'd1 && funct3 != 3'd5) begin
          is_illegal = 1'b0;
          reg_write  = 1'b1;
          alu_src    = 1'b1;
          case (funct3)
            3'd0:    alu_op = ALU_ADD;
            3'd2:    alu_op = ALU_SLT;
            3'd3:    alu_op = ALU_SLTU;
            3'd4:    alu_op = ALU_XOR;
            3'd6:    alu_op = ALU_OR;
            3'd7:    alu_op = ALU_AND;
            default: alu_op = ALU_ADD;
          endcase
        end else if (funct3 == 3'd1 && funct7 == 7'b0000000) begin // SLLI
          is_illegal = 1'b0;
          reg_write  = 1'b1;
          alu_src    = 1'b1;
          alu_op     = ALU_SLL;
        end else if (funct3 == 3'd5 && funct7 == 7'b0000000) begin // SRLI
          is_illegal = 1'b0;
          reg_write  = 1'b1;
          alu_src    = 1'b1;
          alu_op     = ALU_SRL;
        end else if (funct3 == 3'd5 && funct7 == 7'b0100000) begin // SRAI
          is_illegal = 1'b0;
          reg_write  = 1'b1;
          alu_src    = 1'b1;
          alu_op     = ALU_SRA;
        end
      end

      // ── LOAD ────────────────────────────────────────────────────────────
      7'b0000011: begin
        // funct3 valid set: 0(LB), 1(LH), 2(LW), 4(LBU), 5(LHU). 3/6/7 reserved.
        if (funct3 == 3'd0 || funct3 == 3'd1 || funct3 == 3'd2 ||
            funct3 == 3'd4 || funct3 == 3'd5) begin
          is_illegal = 1'b0;
          mem_read   = 1'b1;
          mem_to_reg = 1'b1;
          reg_write  = 1'b1;
          alu_src    = 1'b1;
          case (funct3)
            3'd0, 3'd4: mem_width = 2'd0;
            3'd1, 3'd5: mem_width = 2'd1;
            3'd2:       mem_width = 2'd2;
            default:    mem_width = 2'd2;
          endcase
          mem_sext = ~funct3[2];  // L*U have funct3[2]=1 -> sext=0
        end
      end

      // ── STORE ───────────────────────────────────────────────────────────
      7'b0100011: begin
        // funct3 valid set: 0(SB), 1(SH), 2(SW). 3..7 reserved.
        if (funct3 == 3'd0 || funct3 == 3'd1 || funct3 == 3'd2) begin
          is_illegal = 1'b0;
          mem_write  = 1'b1;
          alu_src    = 1'b1;
          case (funct3)
            3'd0:    mem_width = 2'd0;
            3'd1:    mem_width = 2'd1;
            3'd2:    mem_width = 2'd2;
            default: mem_width = 2'd2;
          endcase
        end
      end

      // ── BRANCH ──────────────────────────────────────────────────────────
      7'b1100011: begin
        // funct3 valid set: 0(BEQ), 1(BNE), 4(BLT), 5(BGE), 6(BLTU), 7(BGEU).
        // 2/3 reserved.
        if (funct3 != 3'd2 && funct3 != 3'd3) begin
          is_illegal = 1'b0;
          is_branch  = 1'b1;
          branch_op  = funct3;
        end
      end

      // ── JAL / JALR ──────────────────────────────────────────────────────
      7'b1101111: begin // JAL
        is_illegal = 1'b0;
        is_jump    = 1'b1;
        reg_write  = 1'b1;
      end
      7'b1100111: begin // JALR — funct3 must be 0
        if (funct3 == 3'd0) begin
          is_illegal = 1'b0;
          is_jump    = 1'b1;
          is_jalr    = 1'b1;
          reg_write  = 1'b1;
          alu_src    = 1'b1;
        end
      end

      // ── LUI / AUIPC ─────────────────────────────────────────────────────
      7'b0110111: begin // LUI
        is_illegal = 1'b0;
        is_lui     = 1'b1;
        reg_write  = 1'b1;
        alu_op     = ALU_LUI;
        alu_src    = 1'b1;
      end
      7'b0010111: begin // AUIPC
        is_illegal = 1'b0;
        is_auipc   = 1'b1;
        reg_write  = 1'b1;
        alu_src    = 1'b1;
      end

      // ── MISC-MEM (FENCE / FENCE.I) — architectural NOP ─────────────────
      7'b0001111: begin
        is_illegal = 1'b0;
      end

      // ── SYSTEM — only EBREAK accepted ───────────────────────────────────
      7'b1110011: begin
        if (instr == 32'h00100073) begin
          is_illegal = 1'b0;
        end
      end

      default: ; // is_illegal stays 1
    endcase
  end

endmodule
