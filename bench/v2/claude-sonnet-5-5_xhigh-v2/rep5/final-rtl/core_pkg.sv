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
    logic       is_illegal;  // default-true in decoder; cleared inside
                              // validated opcode/funct arms only.
    // One-hot EX result select, decoded in ID from alu_op / is_jump so EX
    // builds the EX/MEM alu_result as a flat AND-OR instead of a 5-bit case
    // (all zero on a bubble). alu_op itself is still carried for the MDU.
    logic       sel_add;     // adder result (ADD/SUB, address calc, AUIPC)
    logic       sel_and;
    logic       sel_or;
    logic       sel_xor;
    logic       sel_slt;     // SLT / SLTU
    logic       sel_shift;   // SLL / SRL / SRA
    logic       sel_lui;     // LUI
    logic       sel_mdu;     // MUL/DIV/REM (MDU result register)
    logic       sel_pc4;     // JAL / JALR link value
    // Sub-op controls for the shared adder / shifter (decoded in ID).
    logic       alu_sub;     // adder computes a - b (SUB, SLT, SLTU)
    logic       slt_u;       // SLTU (unsigned compare)
    logic       sh_left;     // SLL
    logic       sh_arith;    // SRA
  } ctrl_t;

  // IF -> ID combinational bundle (no register; PC reg sits in if_stage).
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
    logic        valid;
    logic        pred_taken;  // IF predicted this JAL/BRANCH taken (0 on bubbles)
  } if_id_t;

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
    logic        pred_taken;  // carried from IF; EX redirects iff actual != pred
    // Forward match precomputed in ID (rs != 0 && rs == rd of the
    // instruction ahead): m1 = the instruction that is in EX/MEM while this
    // one is in EX. EX only ANDs these with the registered reg_write bit of
    // that stage. The MEM/WB leg is resolved in ID instead (late bypass of
    // the MEM-stage result into rs?_val, see id_stage.sv).
    logic        m1_rs1;
    logic        m1_rs2;
    // ALU operands pre-selected in ID so EX needs a single 2:1 mux per ALU
    // operand: alu_a_val = is_auipc ? pc : rs1_val, alu_b_val = alu_src ?
    // imm : rs2_val; the matching EX/MEM forward selects are m1_alu_a =
    // m1_rs1 && !is_auipc, m1_alu_b = m1_rs2 && !alu_src.
    logic [31:0] alu_a_val;
    logic [31:0] alu_b_val;
    logic        m1_alu_a;
    logic        m1_alu_b;
  } id_ex_t;

  // EX/MEM register payload.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] alu_result;
    logic [31:0] write_data;     // raw rs2 (post-forward), pre byte replication
    logic [4:0]  rd;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    logic [31:0] rs1_val;        // post-forward rs1 used by EX
    logic [31:0] rs2_val;        // post-forward rs2 used by EX
    logic [31:0] pc_next;        // resolved next-PC (target / pc+4)
    logic        branch_taken;
    logic [31:0] branch_target;
    // Registered redirect (resolved in EX, acted on one cycle later from
    // MEM): `redirect` is already qualified with valid and the misalign
    // suppression, `redirect_target` does not depend on the compare result.
    logic        redirect;
    logic [31:0] redirect_target;
    // rs1 + imm: the only source of dmem_addr / byte mask / misalign / load
    // align in MEM (alu_result stays the write-back / forward value).
    logic [31:0] mem_addr;
    ctrl_t       ctrl;
    logic [31:0] instr;
    logic        valid;
  } ex_mem_t;

  // MEM/WB register payload — mirrors the RVFI-feeding contract.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] alu_result;
    logic [31:0] read_data;      // sign/zero-extended load (for regfile write)
    logic [31:0] wb_data;        // mem_to_reg ? read_data : alu_result, premuxed
                                 // in MEM so the EX forward path starts at a flop
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
