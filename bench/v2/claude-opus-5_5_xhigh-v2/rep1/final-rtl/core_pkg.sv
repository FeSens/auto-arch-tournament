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
    logic       is_div;      // DIV/DIVU/REM/REMU -> sequential divider
  } ctrl_t;

  // IF -> ID combinational bundle (no register; PC reg sits in if_stage).
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
    logic        valid;
  } if_id_t;

  // ID/EX register payload.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] rs1_val;        // post-forward (ID bypass network)
    logic [31:0] rs2_val;        // post-forward (ID bypass network)
    logic [31:0] imm;
    logic [4:0]  rd;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    ctrl_t       ctrl;
    logic [31:0] instr;
    logic        valid;
    // ID-precomputed, operand-independent values.
    logic [31:0] pre_result;     // LUI imm / AUIPC pc+imm / JAL(R) pc+4
    logic [31:0] branch_target;  // pc + imm (branch / JAL target)
    // One-hot EX/MEM.alu_result lane selects (see alu_dec in alu.sv).
    // All zero for MUL*: the product rides EX/MEM.mul_p instead.
    logic        sel_add;
    logic        sub;
    logic [1:0]  lop;
    logic        sel_sll;
    logic        sel_sr;
    logic        sh_arith;
    logic        sel_slt;
    logic        slt_u;
    logic        sel_div;
    logic        sel_pre;
    // Multiply: product half select (MEM) and operand extension bits.
    logic        sel_mul_lo;
    logic        sel_mul_hi;
    logic        mul_a_sx;
    logic        mul_b_sx;
    // Result only available in MEM (LOAD, MUL*): load/mul-use interlock.
    logic        late_result;
    // Branch prediction (branch_pred.sv): the table value read at predict
    // time (for training).
    logic [1:0]  ctr;
    // One-hot "redirect when" flags, folded in ID from pred, funct3 and
    // the target alignment: EX redirects iff the flagged compare holds.
    logic        f_eq;           // redirect when rs1 == rs2
    logic        f_ne;           // redirect when rs1 != rs2
    logic        f_lt;           // redirect when rs1 <  rs2 (signed)
    logic        f_ge;           // redirect when rs1 >= rs2 (signed)
    logic        f_ltu;          // redirect when rs1 <  rs2 (unsigned)
    logic        f_geu;          // redirect when rs1 >= rs2 (unsigned)
    logic        f_jal;          // unpredicted aligned JAL
    logic        f_jr;           // JALR (redirect unless misaligned)
    // Mispredict target for everything but JALR: pred ? pc+4 : pc+imm.
    logic [31:0] alt_target;
  } id_ex_t;

  // EX/MEM register payload.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] alu_result;
    logic [31:0] mem_addr;       // AGU: rs1 + imm (LOAD/STORE address)
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
    // Product half select into alu_or_mul (the 64-bit product itself is
    // a separate, reset-free EX/MEM register so it packs into the DSP).
    logic        sel_mul_lo;
    logic        sel_mul_hi;
    // Pre-decoded load byte lanes (from agu_sum[1:0] / width / sext).
    logic [1:0]  ld_b0_idx;      // rdata byte -> result byte 0
    logic        ld_b1_lo;       // result byte 1 = rdata[15:8]
    logic        ld_b1_hi;       // result byte 1 = rdata[31:24]
    logic        ld_hi_word;     // result[31:16] = rdata[31:16]
    logic [1:0]  ld_sgn_idx;     // sign = rdata[8*idx + 7]
    logic        ld_sx_b1;       // result byte 1 = sign fill
    logic        ld_sx_hi;       // result[31:16] = sign fill
    // Predictor counter read at predict time (training, branch_pred.sv).
    logic [1:0]  ctr;
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
