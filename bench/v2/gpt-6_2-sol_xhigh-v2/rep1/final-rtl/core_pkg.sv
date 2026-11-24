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
    logic       branch_equality;
    logic [1:0] uses_rs;    // {rs2, rs1}, architectural operands
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

  // IF -> ID combinational bundle for the presented fetch request.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] pc_plus4;
    logic [31:0] instr;
    logic        btb_hit;
    logic [1:0]  btb_counter;
  } if_id_t;

  typedef struct packed {
    logic other;
    logic add;
    logic shift;
    logic div;
    logic mul;
    logic load;
  } result_sel_t;

  typedef struct packed {
    result_sel_t result;
    logic        wb;
    logic        regfile;
  } fwd_sel_t;

  // ID/EX register payload.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] pc_plus4;
    logic [31:0] direct_target;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
    logic [31:0] imm;
    logic [4:0]  rd;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    logic [1:0]  ex_match;      // {rs2, rs1}, producer advances to EX/MEM
    logic [1:0]  mem_match;     // {rs2, rs1}, producer advances to MEM/WB
    ctrl_t       ctrl;
    logic [31:0] instr;
    logic        btb_hit;
    logic [1:0]  btb_counter;
    logic        valid;
  } id_ex_t;

  // Resolved direction and successor matches for the recovery cycle.
  typedef struct packed {
    logic [31:0] target;
    logic [31:0] fallthrough;
    logic        match_target;
    logic        match_fallthrough;
    logic        take_target;
    logic        refetch;
    logic        valid;
  } fetch_resolution_t;

  typedef struct packed {
    logic        write_counter;
    logic        write_target;
    logic [1:0]  counter;
  } btb_action_t;

  // The two possible writes share the PC and target. IF can apply each
  // candidate to the ordinary lookup before the comparison is reduced.
  typedef struct packed {
    logic [17:0] pc_word;
    logic [17:0] target_word;
    btb_action_t taken;
    btb_action_t not_taken;
  } btb_training_t;

  // Selected write for the predictor and ID metadata repair.
  typedef struct packed {
    logic        write_counter;
    logic        write_target;
    logic [17:0] pc_word;
    logic [17:0] target_word;
    logic [1:0]  counter;
  } btb_update_t;

  // Each byte and sign mask indexes the unformatted memory response.
  typedef struct packed {
    logic [3:0] low_bytes;
    logic [1:0] mid_bytes;
    logic       high_half;
    logic [3:0] mid_sign;
    logic [3:0] high_sign;
    logic [3:0] bit15;
    logic [3:0] bit31;
  } load_format_t;

  // EX/MEM register payload.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] other_result;
    logic [31:0] add_result;
    logic [31:0] shift_result;
    logic [31:0] div_result;
    logic [31:0] mul_result;
    result_sel_t result_sel;
    logic [31:0] effective_addr;
    load_format_t load_format;
    logic        mem_misalign;
    logic [31:0] write_data;     // raw rs2 (post-forward), pre byte replication
    logic [4:0]  rd;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    logic [31:0] rs1_val;        // post-forward rs1 used by EX
    logic [31:0] rs2_val;        // post-forward rs2 used by EX
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
    logic        reg_write;
    logic        trap;
    logic [31:0] instr;
    logic        valid;
  } mem_wb_t;

`endif // CORE_PKG_DEFINED
