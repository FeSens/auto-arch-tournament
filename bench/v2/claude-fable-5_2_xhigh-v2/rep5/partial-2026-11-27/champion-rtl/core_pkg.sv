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

  // ── ALU operations (decoder-level encoding; EX uses one-hot selects) ────
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
  localparam logic [2:0] BR_BEQ  = 3'd0;
  /* verilator lint_off UNUSEDPARAM */
  localparam logic [2:0] BR_BNE  = 3'd1;
  localparam logic [2:0] BR_BLT  = 3'd4;
  localparam logic [2:0] BR_BGE  = 3'd5;
  localparam logic [2:0] BR_BLTU = 3'd6;
  localparam logic [2:0] BR_BGEU = 3'd7;
  /* verilator lint_on UNUSEDPARAM */

  // ── Pipeline-bundle typedefs ────────────────────────────────────────────
  // Control bits that travel past EX (MEM / WB / RVFI). The EX-only
  // pre-decoded selects live directly in id_ex_t.
  typedef struct packed {
    logic       mem_read;
    logic       mem_write;
    logic [1:0] mem_width;   // 0 = byte, 1 = half, 2 = word
    logic       mem_sext;    // sign-extend load result
    logic       reg_write;
    logic       mem_to_reg;  // 1 = write loaded data, 0 = write ALU result
    logic       is_illegal;  // default-true in decoder; cleared inside
                              // validated opcode/funct arms only.
  } ctrl_t;

  // IF/ID register payload (owned by if_stage). `valid` is reset; the
  // data fields are clock-enable only and hold garbage when !valid.
  // Bubbles into ID/EX are made by hazard_unit.kill_id (load-use, empty
  // IF/ID, flush).
  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] pc4;        // pc + 4 (shared with the PC incrementer)
    logic [31:0] tgt;        // pc + B-imm / pc + J-imm (fetch-cycle adders)
    logic        pred_taken; // fetch followed `tgt` (aligned JAL / predicted branch)
    logic [1:0]  pht;        // PHT entry read for this pc (training)
    logic        fl;         // fetched in a flush cycle: not steered, and the
                             // PHT entry was read with a stale index
    logic [31:0] instr;
  } if_id_t;

  // ID/EX register payload.
  //
  // Two groups (see id_stage.sv):
  //   data    : clock-enable only, NEVER cleared (not by reset, not by a
  //             flush). Holds garbage in a bubble.
  //   control : valid + every bit with a side effect; synchronously
  //             cleared on reset / kill. A bubble is "all control bits 0".
  typedef struct packed {
    // ── data group ──────────────────────────────────────────────────────
    logic [31:0] pc;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
    logic [31:0] imm;
    logic [31:0] op_a;         // ALU operand a: pc (AUIPC), 0 (LUI), else rs1
    logic [31:0] op_b;         // ALU operand b: imm (alu_src) else rs2
    logic [31:0] link;         // pc + 4 for JAL/JALR, else 0 (pre-gated)
    logic [31:0] btarget;      // ALTERNATE next pc: the path fetch did NOT
                               // follow (pc+imm, or pc+4 when predicted taken)
    logic [31:0] npc_pred;     // next pc fetch DID follow (RVFI pc_wdata only)
    logic [1:0]  pht;          // PHT entry read at fetch (training)
    logic [4:0]  rd;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    // Forwarding selects, FULLY qualified in ID (rd != 0 && rd == rs &&
    // the producer's reg_write as it will be registered next cycle):
    //   *_ex  : forward from EX/MEM when this instruction is in EX
    // (The producer two ahead is bypassed in ID: its value is written
    // straight into rs1_val / rs2_val / op_a / op_b at capture.)
    // rs1/rs2: raw register operands (branch compare, address adder,
    //          store data, muldiv, RVFI).
    // a/b    : ALU operands; cleared in ID when the operand is not a
    //          register read (pc / 0 / imm).
    logic        fwd_rs1_ex;
    logic        fwd_rs2_ex;
    logic        fwd_a_ex;
    logic        fwd_b_ex;
    // One-hot ALU result-class selects (all 0 when rd is not an ALU value).
    logic        sel_add;      // a +/- b
    logic        alu_sub;      // adder subtracts (SUB / SLT / SLTU)
    logic        sel_slt;      // {31'b0, a < b}
    logic        slt_signed;
    logic [1:0]  logic_op;     // 00 none, 01 AND, 10 OR, 11 XOR
    logic        sel_shl;
    logic        sel_shr;
    logic        sh_arith;
    // Branch compare selects.
    logic        br_use_eq;    // 1: eq compare, 0: lt compare
    logic        br_signed;    // lt compare is signed
    logic        br_inv;       // invert (BNE / BGE / BGEU)
    logic [31:0] instr;
    // ── control group ───────────────────────────────────────────────────
    logic        is_muldiv;    // RV32M op: executed by the sequential muldiv unit
    // Redirect decision as a function of the selected compare result c
    // (c = br_use_eq ? eq : lt):  redirect = jalr_go | (c ? redir_c1 : redir_c0)
    // The fetch-cycle prediction is folded in, so a redirect is a MISPREDICT:
    //   JAL  (aligned)          : c1 = c0 = !pred_taken (followed in fetch
    //                             unless it was fetched in a flush cycle)
    //   branch (aligned target) : c1 = (br_inv == pred_taken), c0 = !c1
    logic        redir_c1;
    logic        redir_c0;
    logic        bp_train;     // aligned branch whose PHT read was valid
                               // (not fetched in a flush cycle): trains the PHT
    logic        is_jalr;      // JALR: redirects iff (rs1+imm)[1] == 0
    logic        br_bad;       // branch with a misaligned target (traps if taken)
    ctrl_t       ctrl;         // mem_read/mem_write/reg_write/is_illegal are
                               // control group; width/sext/mem_to_reg are data
    logic        valid;
  } id_ex_t;

  // EX/MEM register payload. Only valid and ctrl.{reg_write, mem_read,
  // mem_write, is_illegal} are reset / bubbled; the rest is clock-enable
  // only (see ex_stage.sv).
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] alu_result;
    logic [31:0] mem_addr;       // rs1 + imm (dedicated data-address adder)
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
    logic [31:0] rd_val;         // pre-muxed rd value (load data or ALU result)
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
