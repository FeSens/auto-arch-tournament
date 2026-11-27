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
    logic       is_mul;      // M-ext MUL/MULH/MULHSU/MULHU (multi-cycle in EX)
    logic       is_div;      // M-ext DIV/DIVU/REM/REMU     (multi-cycle in EX)
  } ctrl_t;

  // IF -> ID combinational bundle (no register; PC reg sits in if_stage).
  // The prediction fields sit at the TOP of the packed struct so the low
  // 65 bits keep the {pc, instr, valid} layout the fetch unit tests slice.
  typedef struct packed {
    // Fetch-time branch prediction: PC was already steered to pc + bimm
    // behind this word (only ever 1 for a legal, 4-byte aligned
    // conditional branch). pred_ctr is the 2-bit PHT counter read at
    // fetch; it rides along so training needs no second PHT read port.
    logic        pred_taken;
    logic [1:0]  pred_ctr;
    logic [31:0] pc;
    logic [31:0] instr;
    logic        valid;
  } if_id_t;

  // ID/EX register payload.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
    // Pre-muxed ALU operands (decided in ID): op_a = AUIPC ? pc : rs1,
    // op_b = alu_src ? imm : rs2. fwd_a / fwd_b are the matching forward
    // selects (forced to 00 when the operand is pc / imm).
    logic [31:0] op_a;
    logic [31:0] op_b;
    logic [31:0] imm;
    logic [4:0]  rd;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    // Forwarding selects computed in ID (forward_unit) and registered
    // with ID/EX: 00 = ID/EX value, 01 = EX/MEM, 10 = MEM/WB.
    logic [1:0]  fwd_rs1;
    logic [1:0]  fwd_rs2;
    logic [1:0]  fwd_a;
    logic [1:0]  fwd_b;
    // Pre-decoded: the EX result is the ALU adder output (ADD/SUB/address
    // ops, not a jump). Lets EX select the carry chain in the last level.
    logic        sel_add;
    // Pre-decoded redirect qualifiers (pc + imm alignment is known in ID):
    //   br_ok  / br_bad  : conditional branch whose target is / is not
    //                      4-byte aligned
    //   jal_bad          : JAL whose target is not aligned (an aligned
    //                      JAL is folded at fetch time and needs no
    //                      EX-side redirect qualifier)
    // (JALR alignment depends on rs1 and is resolved in EX.)
    logic        br_ok;
    logic        br_bad;
    logic        jal_bad;
    // Fetch-time prediction of this (aligned, legal) conditional branch
    // and the PHT counter it was predicted with.
    logic        pred_taken;
    logic [1:0]  pred_ctr;
    ctrl_t       ctrl;
    logic [31:0] instr;
    logic        valid;
  } id_ex_t;

  // EX/MEM register payload.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] alu_result;
    logic [31:0] mem_addr;       // rs1 + imm straight off its own adder: the
                                 // dmem address (== alu_result for LOAD/STORE)
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
    logic [31:0] alu_result;     // write-back value: load data for LOADs,
                                 // EX result otherwise (mux before the reg)
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
