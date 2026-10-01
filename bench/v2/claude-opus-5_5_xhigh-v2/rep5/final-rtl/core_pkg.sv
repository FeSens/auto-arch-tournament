// rtl/core_pkg.sv
//
// Core-wide constants and pipeline-bundle types.
//
// Compilation-unit scope (no `package … endpackage` wrapper) because
// Yosys's Verilog frontend rejects `import pkg::*;` even though it
// accepts `pkg::sym` refs and package definitions. A file-scope
// definition with an `\`ifndef` guard is the lowest common denominator
// across Verilator, Yosys, sby, and nextpnr-himbaechel.
//
// Order matters: this file MUST be the first source passed to any tool
// (Verilator/cocotb runner / build.sh / formal staging). Subsequent
// includes hit the guard and become no-ops.
//
// Latency:        n/a (declarations only).
// RVFI fields:    none (defines types; no logic).
`ifndef CORE_PKG_DEFINED
`define CORE_PKG_DEFINED

  // ── ALU operations ──────────────────────────────────────────────────────
  localparam logic [4:0] ALU_ADD    = 5'd0;
  localparam logic [4:0] ALU_SUB    = 5'd1;
  localparam logic [4:0] ALU_AND    = 5'd2;
  localparam logic [4:0] ALU_OR     = 5'd3;
  localparam logic [4:0] ALU_XOR    = 5'd4;
  localparam logic [4:0] ALU_SLT    = 5'd5;
  localparam logic [4:0] ALU_SLTU   = 5'd6;
  localparam logic [4:0] ALU_SLL    = 5'd7;
  localparam logic [4:0] ALU_SRL    = 5'd8;
  localparam logic [4:0] ALU_SRA    = 5'd9;
  localparam logic [4:0] ALU_LUI    = 5'd10;
  localparam logic [4:0] ALU_MUL    = 5'd11;
  localparam logic [4:0] ALU_MULH   = 5'd12;
  localparam logic [4:0] ALU_MULHU  = 5'd13;
  localparam logic [4:0] ALU_MULHSU = 5'd14;
  localparam logic [4:0] ALU_DIV    = 5'd15;
  localparam logic [4:0] ALU_DIVU   = 5'd16;
  localparam logic [4:0] ALU_REM    = 5'd17;
  localparam logic [4:0] ALU_REMU   = 5'd18;

  // ── Branch operations (encoded = funct3 of BRANCH opcode) ───────────────
  // Phase 1 only references BR_BEQ (decoder default). The rest are
  // referenced by the EX-stage comparator in phase 2; we keep them here
  // for documentation and silence UNUSEDPARAM until then.
  localparam logic [2:0] BR_BEQ  = 3'd0;
  /* verilator lint_off UNUSEDPARAM */
  localparam logic [2:0] BR_BNE  = 3'd1;
  localparam logic [2:0] BR_BLT  = 3'd4;
  localparam logic [2:0] BR_BGE  = 3'd5;
  localparam logic [2:0] BR_BLTU = 3'd6;
  localparam logic [2:0] BR_BGEU = 3'd7;
  /* verilator lint_on UNUSEDPARAM */

  // ── Pipeline-bundle typedefs ────────────────────────────────────────────
  typedef struct packed {
    logic [4:0] alu_op;
    logic       alu_src;     // 0 = rs2 value, 1 = immediate
    logic [2:0] branch_op;
    logic       is_branch;
    logic       is_jump;
    logic       is_jalr;
    logic       is_lui;
    logic       is_auipc;
    logic       mem_read;
    logic       mem_write;
    logic [1:0] mem_width;   // 0 = byte, 1 = half, 2 = word
    logic       mem_sext;    // sign-extend load result
    logic       reg_write;
    logic       mem_to_reg;  // 1 = write loaded data, 0 = write ALU result
    logic       is_div;      // DIV/DIVU/REM/REMU -> iterative div_unit
    logic       is_illegal;  // default-true in decoder; cleared inside
                              // validated opcode/funct arms only.
  } ctrl_t;

  // IF -> ID combinational bundle (no register; PC reg sits in if_stage).
  // instr is the raw imem word (don't-care when valid = 0); pred_taken /
  // bht_ctr / alt_target come from the IF branch predictor.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
    logic        valid;
    logic        pred_taken;
    logic [1:0]  bht_ctr;
    logic [31:0] alt_target;
  } if_id_t;

  // ID/EX register payload.
  //
  // s?_ex / s?_wb / s?_rf are one-hot, priority-resolved forward selects
  // computed in ID: rs? (non-x0) equals the rd of the instruction that
  // will sit in EX/MEM (resp. MEM/WB) when this instruction is in EX, AND
  // that instruction's reg_write as EX/MEM (resp. MEM/WB) will capture it
  // (misaligned jump / misaligned memory access already folded in).
  // _rf selects the ID-registered value. EX's operand muxes are pure
  // flop-selected AND-ORs.
  //
  // The ALU's immediate operand (folded into opb_val) is imm, or 4 for
  // JAL/JALR so the ALU itself produces the link address (pc + 4).
  //
  // opa_val / opb_val are the ALU operands pre-selected in ID (pc or rs1,
  // alu_imm or rs2); sa_* / sb_* are s1_* / s2_* with the forward arms
  // masked off when the operand is pc / immediate (sa_rf / sb_rf pick
  // opa_val / opb_val).
  //
  // mul_* are the registered MUL selects (from the decoder) so the DSP
  // output meets a single flop-selected mux in EX.
  //
  // sel_* are the mispredict selects precomputed in ID: one-hot branch
  // condition selects, already gated with "target aligned" (!imm[1]; the
  // PC is always word-aligned so the branch target's low bits are
  // imm[1:0], and imm[0] is always 0) and with the IF prediction folded
  // in (a predicted-taken BEQ selects the "ne" condition, etc.), so EX's
  // redirect fires only on a mispredict. An aligned JAL is always
  // predicted taken in IF and never redirects.
  //
  // pred / bht_ctr are the IF prediction and the BHT counter it read
  // (training snapshot); alt_target is where the branch goes if the
  // prediction was wrong (pc + 4 if predicted taken, else pc + imm).
  //
  // Only the control subset (valid, ctrl.reg_write/mem_read/mem_write/
  // is_branch/is_jump/is_jalr/is_div/is_illegal, sel_*, pred) is cleared
  // by an ID/EX flush or an imem-stall bubble; everything else is plain
  // datapath.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
    logic [31:0] opa_val;
    logic [31:0] opb_val;
    logic [31:0] imm;
    logic        s1_ex;
    logic        s1_wb;
    logic        s1_rf;
    logic        s2_ex;
    logic        s2_wb;
    logic        s2_rf;
    logic        sa_ex;
    logic        sa_wb;
    logic        sa_rf;
    logic        sb_ex;
    logic        sb_wb;
    logic        sb_rf;
    logic        mul_sel;
    logic        mul_hi;
    logic        mul_a_signed;
    logic        mul_b_signed;
    logic        sel_eq;
    logic        sel_ne;
    logic        sel_lt;
    logic        sel_ge;
    logic        sel_ltu;
    logic        sel_geu;
    logic        pred;
    logic [1:0]  bht_ctr;
    logic [31:0] alt_target;
    logic [4:0]  rd;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    ctrl_t       ctrl;
    logic [31:0] instr;
    logic        valid;
  } id_ex_t;

  // EX/MEM register payload.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] alu_result;
    logic [31:0] mem_addr;       // AGU result (rs1 + imm): drives dmem
    logic [31:0] write_data;     // raw rs2 (post-forward), pre byte replication
    logic [4:0]  rd;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    logic [31:0] rs1_val;        // post-forward rs1 used by EX
    logic [31:0] rs2_val;        // post-forward rs2 used by EX
    logic [31:0] pc_next;        // resolved next-PC (target / pc+4)
    logic        branch_taken;
    logic [31:0] branch_target;
    ctrl_t       ctrl;
    logic [31:0] instr;
    logic        valid;
  } ex_mem_t;

  // MEM/WB register payload — mirrors the RVFI-feeding contract.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] wb_data;        // regfile write data (load or ALU result),
                                 // selected in MEM
    logic [4:0]  rd;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
    logic [31:0] pc_next;
    logic [31:0] mem_addr;       // word-aligned for RVFI ALIGNED_MEM
    logic [31:0] mem_rdata;      // raw memory word
    logic [31:0] mem_wdata;      // replicated byte-lane write data
    logic [3:0]  mem_wmask;
    logic [3:0]  mem_rmask;
    ctrl_t       ctrl;
    logic [31:0] instr;
    logic        valid;
  } mem_wb_t;

`endif // CORE_PKG_DEFINED
