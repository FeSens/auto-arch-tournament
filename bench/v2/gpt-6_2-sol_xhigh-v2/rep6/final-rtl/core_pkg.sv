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

  typedef enum logic [1:0] {
    RESULT_FAST, RESULT_LOAD, RESULT_MUL, RESULT_DIV
  } result_kind_t;

  typedef struct packed {
`ifdef RISCV_FORMAL_ALTOPS
    logic [31:0] alternate;
`else
    logic [31:0] lo_lo;
    logic [32:0] lo_hi;
    logic [32:0] hi_lo;
    logic [31:0] hi_hi;
    logic        high_half;
`endif
  } mul_products_t;

  // ── Pipeline-bundle typedefs ────────────────────────────────────────────
  typedef struct packed {
    logic [4:0] alu_op;
    logic [2:0] branch_op;
    logic       is_branch;
    logic       is_jump;
    logic       is_jalr;
    logic       is_lui;
    logic       mem_read;
    logic       mem_write;
    logic [1:0] mem_width;   // 0 = byte, 1 = half, 2 = word
    logic       mem_sext;    // sign-extend load result
    logic       reg_write;
    logic       is_illegal;  // default-true in decoder; cleared inside
                              // validated opcode/funct arms only.
  } ctrl_t;

  // IF -> ID combinational bundle from the fetch queue or its live input.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
    logic        predicted_taken;
    logic        valid;
  } if_id_t;

  typedef struct packed {
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic       aligned_branch;
  } fetch_hazard_t;

  typedef struct packed {
    logic       valid;
    logic [5:0] index;
    logic       taken;
  } predictor_update_t;

  typedef struct packed {
    logic [11:2] target_word;
    logic        cold_taken;
    logic        branch;
    logic        jal;
  } replay_steering_t;

  typedef struct packed {
    logic        valid;
    logic [31:2] pc;
    logic [31:2] instr;  // Replay only records legal 32-bit instructions.
    logic [11:2] target_word;
    logic        branch;
    logic        jal;
  } replay_update_t;

  typedef struct packed {
    logic local_value;
    logic ex_mem;
    logic mem_wb;
  } operand_sel_t;

  typedef struct packed {
    logic rs1;
    logic rs2;
  } load_match_t;

  typedef struct packed {
    load_match_t match;
    logic        load_writes;
    logic [3:0]  byte_equal;
    logic [3:0]  byte_less;
    logic        load_sign;
    logic        other_sign;
    logic        predicted_taken;
    logic [31:2] target;       // Exact EX direct target, independent of direction.
    logic [31:2] fallthrough;
  } late_branch_t;

  // ID/EX register payload.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
    logic [31:0] alu_a_local;
    logic [31:0] alu_b_local;
    operand_sel_t rs1_sel;
    operand_sel_t rs2_sel;
    operand_sel_t alu_a_sel;
    operand_sel_t alu_b_sel;
    logic [31:0] imm;
    logic [4:0]  rd;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    ctrl_t       ctrl;
    result_kind_t result_kind;
    logic [31:0] instr;
    logic        predicted_taken;
    logic        branch_recover_eq;
    logic        branch_recover_order;
    logic        branch_recover_invert;
    logic        recover_fallthrough;
    logic        recover_direct;
    logic        recover_indirect;
    logic        fence_i;
    load_match_t load_match;
    logic        load_other_rs1;
    logic        load_other_rs2;
    logic        load_other_wb;
    logic        valid;
  } id_ex_t;

  // EX/MEM register payload.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] alu_result;
    logic [31:0] effective_addr; // byte address for loads and stores
    result_kind_t result_kind;
    mul_products_t mul_products;
    logic [31:0] div_magnitude;
    logic        div_negate;
    logic [31:0] write_data;     // raw rs2 (post-forward), pre byte replication
    logic [4:0]  rd;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    logic [31:0] rs1_val;        // post-forward rs1 used by EX
    logic [31:0] rs2_val;        // post-forward rs2 used by EX
    logic [31:0] pc_next;        // resolved next-PC (target / pc+4)
    late_branch_t late_branch;
    logic        branch_taken;   // ordinary direction, also the trap fallback
    logic [5:0]  branch_index;
    ctrl_t       ctrl;
    logic [31:0] instr;
    logic        valid;
  } ex_mem_t;

  // MEM/WB register payload — mirrors the RVFI-feeding contract.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] result;
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
    logic        reg_write;     // forwarding eligibility, retained on a hold
    logic        trap;
    logic [31:0] instr;
    logic        valid;
  } mem_wb_t;

`endif // CORE_PKG_DEFINED
