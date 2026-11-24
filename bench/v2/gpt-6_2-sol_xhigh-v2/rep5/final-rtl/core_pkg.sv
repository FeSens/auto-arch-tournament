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
// Build flows pass this file first. A wildcard lint build picks up these
// declarations from alu.sv before core.sv references the pipeline types.
// The guard allows both source orders.
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
    logic       is_mul;
    logic       is_div;
    logic       is_illegal;  // default-true in decoder; cleared inside
                              // validated opcode/funct arms only.
  } ctrl_t;

  typedef struct packed {
    logic add, sub, and_op, or_op, xor_op, slt, sltu, sll, srl, sra, lui;
  } alu_select_t;

  function automatic alu_select_t decode_alu(input logic [4:0] op);
    decode_alu = {op == ALU_ADD, op == ALU_SUB, op == ALU_AND, op == ALU_OR,
                  op == ALU_XOR, op == ALU_SLT, op == ALU_SLTU, op == ALU_SLL,
                  op == ALU_SRL, op == ALU_SRA, op == ALU_LUI};
  endfunction

  typedef struct packed {
    logic alu, load, mul, div, late_add, late_double;
  } writeback_select_t;

  // Decoded instruction and the prediction applied when it was fetched.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
    logic [31:0] direct_target;
    logic [31:0] imm;
    ctrl_t       ctrl;
    logic        predicted_taken;
    logic [5:0]  prediction_index;
    logic        holds_fetch;
    logic        late_eligible;
  } issue_packet_t;

  // Exactly one source for a nonzero register. An x0 operand selects none.
  typedef struct packed {
    logic ex_mem;
    logic mem_wb;
    logic reg_file;
  } operand_sel_t;

  // ID/EX register payload.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] direct_target;
    logic        predicted_taken;
    logic [5:0]  prediction_index;
    logic        holds_fetch;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
    operand_sel_t rs1_sel;
    operand_sel_t rs2_sel;
    logic        pending_rs1;
    logic        pending_rs2;
    logic        late_add;
    logic        late_branch;
    alu_select_t alu_select;
    logic [31:0] imm;
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
    logic [31:0] mem_addr;      // effective byte address, including lane bits
    logic [31:0] write_data;     // raw rs2 (post-forward), pre byte replication
    logic [4:0]  rd;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    logic [31:0] rs1_val;        // post-forward rs1 used by EX
    logic [31:0] rs2_val;        // post-forward rs2 used by EX
    logic [31:0] pc_next;        // resolved next-PC (target / pc+4)
    ctrl_t       ctrl;
    writeback_select_t writeback_select;
    logic        pending_rs1;   // the matching producer actually writes
    logic        pending_rs2;
    logic [31:0] late_operand;
    logic        late_branch;
    logic        branch_cond;
    logic        predicted_taken;
    logic [5:0]  prediction_index;
    logic [31:0] branch_target;
    logic [31:0] pc_plus_4;
    logic [31:2] recovery_word;
    logic [31:0] instr;
    logic        valid;
  } ex_mem_t;

  // MEM/WB register payload — mirrors the RVFI-feeding contract.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] result;         // registered value for WB and forwarding
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
