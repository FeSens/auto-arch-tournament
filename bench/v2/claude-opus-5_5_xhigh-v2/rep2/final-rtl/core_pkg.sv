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
  } ctrl_t;

  // One-hot ALU result selects, decoded from alu_op in ID (alu_dec) and
  // registered in ID/EX, so the EX result is an AND-OR of the adder,
  // logic, shifter and set-less-than terms instead of an op case mux.
  typedef struct packed {
    logic       sel_arith;   // ADD / SUB / LUI (a = 0) / link / AUIPC
    logic       sub;         // SUB / SLT / SLTU: adder computes a - b
    logic [1:0] logic_op;    // 00 off, 01 AND, 10 OR, 11 XOR
    logic       sel_sll;
    logic       sel_sr;      // SRL / SRA
    logic       sra;
    logic       sel_slt;
    logic       sel_sltu;
    logic       mul_sa;      // MUL*: a signed (MULH / MULHSU)
    logic       mul_sb;      // MUL*: b signed (MULH)
    logic       mul_hi;      // MUL*: high word (MULH / MULHSU / MULHU)
  } alu_sel_t;

  // IF -> ID combinational bundle (no register; PC reg sits in if_stage).
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
    logic        valid;
    logic        pred;       // IF steered to the B/J target (predict taken)
  } if_id_t;

  // ID/EX register payload.
  //
  // rs1_val / rs2_val / op_a / op_b are captured fully resolved except
  // for the instruction immediately ahead (1-ahead): ID already applied
  // the regfile write-first bypass (3-ahead) and the forward from the
  // MEM-stage result (2-ahead). op_a / op_b are the pre-selected ALU
  // operands (pc for AUIPC/JAL/JALR, imm / 4 on the b side).
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
    logic [31:0] op_a;
    logic [31:0] op_b;
    logic [31:0] imm;
    logic [4:0]  rd;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    // Registered 1-ahead forwarding hits, computed when ID captures this
    // instruction: the instruction then in ID/EX (now in EX/MEM) writes
    // rs?. op_a_hit / op_b_hit are the same hit masked where the ALU
    // operand is not a register. EX qualifies them with the live EX/MEM
    // reg_write bit.
    logic        rs1_hit_ex;
    logic        rs2_hit_ex;
    logic        op_a_hit;
    logic        op_b_hit;
    // pc + imm (branch / JAL target), added in ID.
    logic [31:0] pc_imm;
    // Wrong-path kill: the EX redirect fired the cycle this instruction
    // was captured. EX drops its redirect, its divide and its EX/MEM
    // valid / reg_write / mem_read / mem_write.
    logic        squash;
    // Result not ready 1-ahead (LOAD / MUL* / DIV*): the next consumer
    // takes a one-cycle interlock (hazard_unit). Cleared on squash.
    logic        late;
    // MUL* / DIV*: the result is EX/MEM.xres, selected in MEM.
    logic        res_late;
    alu_sel_t    alu_sel;
    // Branch compare selects: cond = cmp_inv ^ (eq | lt | ltu picked).
    logic        sel_eq;
    logic        sel_lt;
    logic        sel_ltu;
    logic        cmp_inv;
    // Aligned targets (pc is 4-aligned, so the target is misaligned iff
    // imm[1]): br_ok = branch && !imm[1]; jal_ok = JAL && !imm[1];
    // jal_mis = JAL && imm[1].
    logic        br_ok;
    logic        jal_ok;
    logic        jal_mis;
    // IF steered this word to pc + imm. Folded into the selects above:
    // cmp_inv ^= pred, jal_ok &&= !pred, pc_imm = pc + 4, so EX redirects
    // only a wrong steer (to pc + 4). RVFI recovers the real outcome.
    logic        pred;
    // DIV / DIVU / REM / REMU
    logic        is_div;
    logic        div_rem;
    logic        div_signed;
    ctrl_t       ctrl;
    logic [31:0] instr;
    logic        valid;
  } id_ex_t;

  // EX/MEM register payload.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] alu_result;     // base ALU result (never MUL* / DIV*)
    logic [31:0] xres;           // MUL* / DIV* result
    logic        res_late;       // result is xres (MUL* / DIV*)
    logic [31:0] mem_addr;       // dedicated AGU sum rs1 + imm (LOAD/STORE)
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
    logic [31:0] wb_data;        // regfile write value (load data or ALU result)
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
