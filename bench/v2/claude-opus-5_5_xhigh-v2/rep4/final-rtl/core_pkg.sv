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
    logic       is_muldiv;   // M-extension op: runs in the multi-cycle
                              // muldiv unit (alu_op = ALU_MUL..ALU_REMU)
    logic       is_illegal;  // default-true in decoder; cleared inside
                              // validated opcode/funct arms only.
  } ctrl_t;

  // IF -> ID combinational bundle (no register; PC reg sits in if_stage).
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
    logic        valid;
    logic        pred_taken;   // IF predicted taken (PC already steered)
    logic [1:0]  pred_ctr;     // BHT counter read at fetch
  } if_id_t;

  // One-hot EX/MEM result-leg select (result class of a producer):
  //   add : sum leg  (ADD/ADDI/LUI/AUIPC/JAL/JALR link, loads' don't-care)
  //   sub : diff leg (SUB)
  //   sh  : shift leg (SLL/SRL/SRA)
  //   lg  : logic leg (SLT/SLTU/XOR/OR/AND, M-ops' muldiv result)
  typedef struct packed {
    logic add;
    logic sub;
    logic sh;
    logic lg;
  } xsel_t;

  // ID/EX register payload.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
    logic [31:0] imm;
    logic [4:0]  rd;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    ctrl_t       ctrl;
    logic [31:0] instr;
    logic        valid;
    logic        pred_taken;
    logic [1:0]  pred_ctr;
    // One-hot operand selects, precomputed in ID against the instructions
    // that will sit in EX/MEM (x) and MEM/WB (w) while this one is in EX;
    // r = the ID-registered regfile value (write-first bypassed). The x
    // select is split by the producer's result class (xsel_t), so EX
    // forwards straight from the unmerged EX/MEM result legs.
    xsel_t       s1_x;  logic s1_w, s1_r;   // raw rs1 (AGU, RVFI)
    xsel_t       s2_x;  logic s2_w, s2_r;   // raw rs2 (store data, RVFI)
    xsel_t       a_x;   logic a_w, a_r, a_pc; // ALU operand a
    xsel_t       b_x;   logic b_w, b_r;     // ALU operand b
    logic [31:0] b_const;                   // 4 (JAL/JALR), imm, or 0
    xsel_t       p1_x;  logic p1_w, p1_r;   // branch compare operand a
    xsel_t       p2_x;  logic p2_w, p2_r;   // branch compare operand b
    // One-hot branch compare select: cond = (eq|lt|ltu leg) ^ inv.
    logic        c_eq, c_lt, c_ltu, c_inv;
    // ALU leg-internal selects, decoded in ID so EX never decodes alu_op.
    // r_add/r_sub/r_shr only feed the ALU's merged (test) view.
    logic        r_add, r_sub, r_slt, r_sltu;
    logic        r_xor, r_or, r_and;
    logic        r_sll, r_shr, r_sra;
    // Result class of this instruction (which EX/MEM leg holds rd's value).
    xsel_t       k;
  } id_ex_t;

  // EX/MEM register payload.
  typedef struct packed {
    logic [31:0] pc;
    // Unmerged result legs; the result is OR(c & leg) (mem_stage).
    logic [31:0] sum;
    logic [31:0] dif;
    logic [31:0] sh;
    logic [31:0] lg;
    xsel_t       c;              // result class one-hot
    logic [31:0] mem_addr;       // AGU result (rs1 + imm): dmem address
    logic        mem_mis;        // misaligned load/store (trap, no access)
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
    logic [1:0]  pred_ctr;       // BHT counter for the update at EX/MEM
  } ex_mem_t;

  // MEM/WB register payload — mirrors the RVFI-feeding contract.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] wb_data;        // mem_to_reg ? aligned load : alu_result
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
