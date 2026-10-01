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

  // ── One-hot ALU result-class selects (bit indices into alu_sel) ─────────
  // Decoded in ID and registered in ID/EX; EX forms the result as a flat
  // AND-OR of the class results. SR covers SRL/SRA (shift_arith picks the
  // fill); MULHI covers MULH/MULHU/MULHSU (a_signed/b_signed pick the
  // operand extension); DIV covers DIV/DIVU/REM/REMU; PRE is the
  // ID-precomputed LUI / AUIPC / link value.
  localparam int RS_ADD   = 0;
  localparam int RS_SUB   = 1;
  localparam int RS_AND   = 2;
  localparam int RS_OR    = 3;
  localparam int RS_XOR   = 4;
  localparam int RS_SLT   = 5;
  localparam int RS_SLTU  = 6;
  localparam int RS_SLL   = 7;
  localparam int RS_SR    = 8;
  localparam int RS_MULLO = 9;
  localparam int RS_MULHI = 10;
  localparam int RS_DIV   = 11;
  localparam int RS_PRE   = 12;
  localparam int RS_W     = 13;

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
    logic       is_illegal;  // default-true in decoder; cleared inside
                              // validated opcode/funct arms only.
  } ctrl_t;

  // IF -> ID combinational bundle (no register; PC reg sits in if_stage).
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
    logic        valid;
    // Look-ahead BTB prediction for this fetch (pt already masked by
    // redir_q). pred_off = predicted word target - pc word address.
    logic        pt;
    logic        hit;
    logic [1:0]  ctr;
    logic [29:0] pred_off;
  } if_id_t;

  // ID/EX register payload.
  typedef struct packed {
    logic [31:0] pc;
    // Operands resolved in ID against the EX/MEM producer and the regfile
    // (write-first for MEM/WB). EX adds only the EX/MEM bypass.
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
    logic [31:0] op_b;           // alu_src ? imm : resolved rs2
    logic [31:0] imm;
    // ID-precomputed pc-relative values.
    logic [31:0] pc_imm;         // pc + imm: branch / JAL target, AUIPC
    logic [31:0] pc4;            // pc + 4: link value, fall-through
    logic [31:0] pre_result;     // LUI imm / AUIPC pc_imm / link pc4
    logic [RS_W-1:0] alu_sel;    // one-hot result class
    logic        shift_arith;    // SRA / SRAI
    logic        a_signed;       // MULH / MULHSU
    logic        b_signed;       // MULH
    // Pre-decoded branch compare: cond = (use_lt ? lt : eq) ^ inv, with
    // lt a single signed/unsigned (br_uns) 33-bit less-than.
    logic        br_use_lt;      // funct3[2]
    logic        br_inv;         // funct3[0]
    logic        br_uns;         // funct3[1]
    // Kill bits (cleared on flush like valid / is_branch / is_jump):
    // redirect-capable vs. trapping (target misaligned iff imm[1]).
    logic        br_ok;          // BRANCH && !imm[1]
    logic        br_bad;         // BRANCH &&  imm[1]
    // early: JAL && !imm[1] not correctly predicted, or any bad
    // prediction (redirect to e_tgt unconditionally).
    logic        early;
    logic        jal_bad;        // JAL    &&  imm[1]
    logic        jalr_np;        // unpredicted JALR (bit 1 checked in EX)
    // BTB data fields (NOT cleared on flush; only matter under a kill bit).
    logic        pt;             // fetched with a taken prediction
    logic        hit;
    logic [1:0]  ctr;
    logic        replay;         // bad prediction on branch/JALR: refetch pc
    logic        jfix;           // JAL && !imm[1]: early target is pc_imm
    logic [31:0] alt_pc;         // pt ? pc4 : pc_imm
    logic [4:0]  rd;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    ctrl_t       ctrl;
    logic [31:0] instr;
    // Pre-decoded EX/MEM -> EX bypass selects (computed in ID against the
    // ID/EX occupant, which sits in EX/MEM next cycle). fwdb_ex is the
    // operand-B copy (fwd2_ex && !alu_src).
    logic        fwd1_ex;
    logic        fwd2_ex;
    logic        fwdb_ex;
    logic        valid;
  } id_ex_t;

  // EX/MEM register payload.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] alu_result;
    logic [31:0] mem_addr;       // dedicated AGU result (rs1 + imm)
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
    // reg_write && rd != 0 && !(misaligned mem op): the EX/MEM occupant
    // may forward to ID (computed in EX so MEM's misalign check is off
    // the ID forwarding path).
    logic        fwd_ok;
    logic [31:0] instr;
    logic        valid;
    // BTB training (flop-sourced write port in if_stage).
    logic        t_jal;          // JAL && !imm[1]: write ctr = 11
    logic        t_br;           // branch && !imm[1], not replayed
    logic        t_clr;          // bad prediction (not JAL): clear ctr
    logic        t_pt;
    logic        t_hit;
    logic [1:0]  t_ctr;
  } ex_mem_t;

  // MEM/WB register payload — mirrors the RVFI-feeding contract.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] alu_result;
    logic [31:0] read_data;      // sign/zero-extended load (for regfile write)
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
