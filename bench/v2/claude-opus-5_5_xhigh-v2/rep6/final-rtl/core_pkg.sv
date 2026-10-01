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
    logic       is_div;      // DIV/DIVU/REM/REMU: runs on the iterative divider
    logic       is_mul;      // MUL/MULH/MULHU/MULHSU: product formed in MEM
    logic       is_illegal;  // default-true in decoder; cleared inside
                              // validated opcode/funct arms only.
  } ctrl_t;

  // IF -> ID combinational bundle (no register; PC reg sits in if_stage).
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] pc4;            // pc + 4 (IF's carry-chain incrementer)
    logic [31:0] instr;
    logic        valid;
  } if_id_t;

  // Operand-source select (registered in ID/EX).
  //   rf=1 : ID/EX register value (regfile read + ID bypass of the MEM
  //          result and the w_q write; for ALU B also the immediate)
  //   rf=0 : EX/MEM.add_q | EX/MEM.oth_q
  // x0 selects rf, which reads 0.
  typedef struct packed {
    logic rf;
  } opsel_t;

  // ID/EX register payload.
  // The operand selects are computed in ID for the cycle the instruction
  // sits in EX (EX/MEM > register value), so EX sees a registered select
  // and each operand is one 2:1 mux of fabric FFs.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] rs1_val;        // regfile read, write-first bypassed in ID
    logic [31:0] rs2_val;        // regfile read, write-first bypassed in ID
    logic [31:0] b_val;          // ALU B: alu_src ? imm : rs2_val
    logic [31:0] imm;            // raw immediate (AGU operand)
    logic [31:0] link;           // pc + 4
    logic [31:0] br_target;      // pc + imm (BRANCH / JAL / AUIPC), precomputed in ID
    logic        br_misalign;    // br_target[1] (pc is always word-aligned)
    // Operand selects, one (syn_preserve) flop copy per EX operand-mux
    // copy so no select drives more than ~16 loads.
    opsel_t      sel_a_lo;       // rs1 source, main copy bits [15:0]
    opsel_t      sel_a_hi;       // rs1 source, main copy bits [31:16]
    opsel_t      sel_a_sll;      // rs1 source, SLL shifter copy
    opsel_t      sel_a_sr;       // rs1 source, SRL/SRA shifter copy
    opsel_t      sel_a_cmp;      // rs1 source, branch compare copy
    opsel_t      sel_r2_lo;      // rs2 source, main copy bits [15:0]
    opsel_t      sel_r2_hi;      // rs2 source, main copy bits [31:16]
    opsel_t      sel_r2_cmp;     // rs2 source, branch compare copy
    opsel_t      sel_b_lo;       // ALU B source (forced to rf when alu_src)
    opsel_t      sel_b_hi;
    opsel_t      sel_b_shl;      // SLL shift amount copy
    opsel_t      sel_b_shr;      // SRL/SRA shift amount copy
    // ALU result one-hot group selects + flags
    logic        alu_add;        // ADD / SUB (not loads, jumps, AUIPC)
    logic        alu_slt;        // SLT / SLTU (adder in subtract mode)
    logic        alu_sll;
    logic        alu_sr;         // SRL / SRA
    logic        alu_logic;      // AND / OR / XOR / LUI group
    logic [1:0]  alu_lop;        // 00 AND, 01 OR, 10 XOR, 11 pass b (LUI)
    logic        alu_link;       // JAL / JALR: pc + 4
    logic        alu_div;        // DIV / DIVU / REM / REMU
    logic        alu_auipc;      // AUIPC: br_target (pc + imm)
    logic        alu_sub;        // b XOR (subtract)
    logic        alu_cin;        // adder carry-in (= alu_sub, own flop)
    logic        alu_arith;
    logic        alu_uns;
    // MUL: operand sign-extension enables and MEM result selects
    logic        mul_a_sgn;      // MULH / MULHSU
    logic        mul_b_sgn;      // MULH
    logic        mul_lo;         // MUL
    logic        mul_hi;         // MULH / MULHU / MULHSU
    logic        lu_arm;        // (mem_read | is_mul) && rd != 0 (kill bit)
    // Branch condition: cond = (use_lt ? lt : eq) ^ inv, unsigned compare
    logic        br_use_lt;      // BLT / BGE / BLTU / BGEU (funct3[2])
    logic        br_inv;         // BNE / BGE / BGEU        (funct3[0])
    logic        br_uns;
    logic        br_ok;          // is_branch && !br_misalign (kill bit)
    // Fetch prediction (fetch_pred): verified in ID.
    logic        br_inv_t;       // br_inv ^ p_ok_br (take = mispredict)
    logic        p_ok_lo;        // predicted B/J verified (ex_tgt = link)
    logic        p_ok_hi;        //   (copies per PC half)
    logic        jlink;          // jump target = link (JALR / p_bad)
    logic        arch_jump;      // architectural JAL/JALR (RVFI only)
    logic        p_bad;          // prediction did not match the instr
    logic        tr_jal;         // aligned JAL (training class)
    logic        tr_en;          // offset fits off[15:2] and imm[1] == 0
    logic [9:0]  pk_idx;         // predictor key used for this instr
    logic        pk_tm;
    logic [1:0]  pk_ctr;
    logic        pk_v;
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
    // ALU result, split so the adder sum reaches its flop directly. Both
    // halves are 0 for loads and MUL*; EX/MEM forward source = add | oth.
    logic [31:0] add_q;          // adder sum (ADD / SUB, SLT / SLTU in bit 0)
    logic [31:0] oth_q;          // shifters | logic | link / div / AUIPC
    logic [31:0] mem_addr;       // dedicated AGU sum rs1+imm (drives dmem)
    logic [31:0] write_data;     // raw rs2 (post-forward), pre byte replication
    logic [4:0]  rd;
    logic        w_ok;           // ctrl.reg_write && rd != 0 (ID bypass / w_q)
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    logic [31:0] rs1_val;        // post-forward rs1 used by EX (MUL operand a)
    logic [31:0] rs2_val;        // post-forward rs2 used by EX (MUL operand b)
    logic        mul_ax;         // MUL operand a extension bit (mul_a_sgn & rs1[31])
    logic        mul_bx;         // MUL operand b extension bit (mul_b_sgn & rs2[31])
    // One-hot MEM result selects (MUL lo / MUL hi); the ALU halves are
    // already 0 when not selected.
    logic        sel_mlo;
    logic        sel_mhi;
    // Load extraction as an AND-OR of dmem DO bits on registered one-hot
    // lane selects (all 0 unless LOAD, so the load data is 0 otherwise):
    //   [7:0]   : DO byte k when ld_b[k]
    //   [15:8]  : DO[15:8] (ld_h0) / DO[31:24] (ld_h2) / sign fill (ld_hx)
    //   [31:16] : DO[31:16] (ld_w) / sign fill (ld_wx)
    //   sign    : DO[8k+7] when ld_s[k] (0 for unsigned loads)
    logic [3:0]  ld_b;
    logic        ld_h0;
    logic        ld_h2;
    logic        ld_hx;
    logic        ld_w;
    logic        ld_wx;
    logic [3:0]  ld_s;
    logic [31:0] pc_next;        // resolved next-PC (target / pc+4)
    // Predictor training (recomputed in MEM from rs1_val / rs2_val)
    logic        tr_br;          // BRANCH, trainable (pk_v && tr_en)
    logic        tr_jal;         // JAL, trainable (pk_v && tr_en)
    logic        tr_bad;         // p_bad, not trainable: invalidate
    logic        br_use_lt;
    logic        br_inv;
    logic        br_uns;
    logic [13:0] tr_off;         // imm[15:2]
    logic [9:0]  pk_idx;
    logic        pk_tm;
    logic [1:0]  pk_ctr;
    ctrl_t       ctrl;
    logic [31:0] instr;
    logic        valid;
  } ex_mem_t;

  // MEM/WB register payload. {w_en, rd, result} is the registered regfile
  // write port w_q (written the cycle after MEM, also an ID bypass source);
  // every other field is RVFI-only (pruned in synthesis).
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] result;         // regfile write data: load / mul / alu
    logic        w_en;           // regfile write (rd != 0, MEM completed)
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
