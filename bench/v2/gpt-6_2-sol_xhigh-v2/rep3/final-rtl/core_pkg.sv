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

  typedef struct packed {
    logic add;
    logic sub;
    logic other;
    logic mul_low;
    logic mul_high;
  } result_sel_t;

  typedef struct packed {
    logic [31:0] add;
    logic [31:0] sub;
    logic [31:0] other;
    logic [63:0] product;
  } result_lanes_t;

  typedef struct packed {
    result_sel_t ex_mem;
    logic        mem_wb;
  } operand_sel_t;

  typedef struct packed {
    logic eq;
    logic ne;
    logic lt;
    logic ge;
    logic signed_compare;
  } branch_sel_t;

  // Aligned fetch addresses and their successors, in word-address units.
  typedef struct packed {
    logic [31:2] addr;
    logic [31:2] addr_plus_four;
  } pc_pair_t;

  typedef struct packed {
    logic short_load;
    logic equality_branch;
  } pair_decode_t;

  // IF -> ID issue port of the fetch FIFO.
  typedef struct packed {
    pc_pair_t    pc;
    logic        predicted_taken;
    logic [31:0] instr;
    pair_decode_t pair_decode;
    logic        synthetic;
    logic        valid;
  } if_id_t;

  // ID/EX register payload.
  typedef struct packed {
    pc_pair_t    pc;
    logic        predicted_taken;
    logic        direct_target_differs;
    logic        divide;
    logic [31:0] rs1_default;
    logic [31:0] rs2_default;
    logic [31:0] alu_b_default;
    operand_sel_t rs1_sel;
    operand_sel_t rs2_sel;
    operand_sel_t alu_b_sel;
    result_sel_t result_sel;
    branch_sel_t branch_sel;
    logic        load_pair;
    logic        branch_pair;
    logic [1:0]  response_match;
    logic [31:0] imm;
    logic [12:0] jalr_imm_plus_four;
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
    result_lanes_t result;
    result_sel_t result_sel;
    logic [31:0] mem_addr;      // effective byte address
    logic [31:0] write_data;     // raw rs2 (post-forward), pre byte replication
    logic [4:0]  rd;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    logic [31:0] rs1_val;        // post-forward rs1 used by EX
    logic [31:0] rs2_val;        // post-forward rs2 used by EX
    logic [31:0] pc_next;        // resolved next-PC (target / pc+4)
    ctrl_t       ctrl;
    logic [31:0] instr;
    logic        valid;
  } ex_mem_t;

  // MEM/WB register payload — mirrors the RVFI-feeding contract.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] write_data;     // selected EX result or extended load
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

  // Staged predictor update. A zero last-lane mask updates direction only.
  // All saved addresses are word addresses in the 1 MiB imem window.
  typedef struct packed {
    logic        valid;
    logic        taken;
    logic [19:2] source_pc;
    logic [31:0] source_instr;
    logic [19:2] target;
    logic [19:2] resume;
    logic [3:0]  last;
    logic [127:0] words;
  } replay_update_t;

`endif // CORE_PKG_DEFINED
