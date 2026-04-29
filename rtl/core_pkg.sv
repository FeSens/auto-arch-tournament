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
  // RV32M ops use op[4]=1 and op[2:0]=funct3, leaving the common RV32I
  // one-cycle path behind op[4]=0.
  localparam logic [4:0] ALU_MUL    = 5'b10000;
  localparam logic [4:0] ALU_MULH   = 5'b10001;
  localparam logic [4:0] ALU_MULHSU = 5'b10010;
  localparam logic [4:0] ALU_MULHU  = 5'b10011;
  localparam logic [4:0] ALU_DIV    = 5'b10100;
  localparam logic [4:0] ALU_DIVU   = 5'b10101;
  localparam logic [4:0] ALU_REM    = 5'b10110;
  localparam logic [4:0] ALU_REMU   = 5'b10111;

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

  // IF -> ID combinational bundle (no register; PC reg sits in if_stage).
  // instr may be the live imem word or a word supplied by IF's registered
  // lookahead replay predictor during an external imem stall. The replay
  // predictor uses two direct-mapped 128-entry banks indexed by pc[8:2],
  // tagged by pc[31:9], and replaced with a per-index MRU bit. Tag and
  // instruction payload arrays are resetless behind bank valid bits.
  // predicted_taken is outcome-only next-PC prediction metadata, meaningful
  // only when this IF payload advances into ID. IF still chooses concrete
  // targets locally; EX recomputes resolved targets from pc/instr and only
  // needs the predicted taken/not-taken outcome.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
    logic        predicted_taken;
    logic        valid;
  } if_id_t;

  // ID/EX register payload.
  // Source register addresses are derived from instr[19:15] / instr[24:20]
  // where needed; rs1_val/rs2_val carry the register-file data values into EX.
  // predicted_taken carries IF's outcome-only prediction into EX. Targets are
  // recomputed in EX for validation/redirect.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
    logic [31:0] imm;
    logic [4:0]  rd;
    ctrl_t       ctrl;
    logic [31:0] instr;
    logic        predicted_taken;
    logic        valid;
  } id_ex_t;

  // EX/MEM register payload.
  // Source register addresses are recovered from instr in downstream users;
  // rs1_val/rs2_val remain the post-forwarded RVFI source-data value rails.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] alu_result;
    logic [31:0] write_data;     // raw rs2 (post-forward), pre byte replication
    logic [4:0]  rd;
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
  // RVFI source register addresses are sliced from instr at retirement;
  // rs1_val/rs2_val carry the post-forwarded source data values.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] alu_result;
    logic [31:0] read_data;      // sign/zero-extended load (for regfile write)
    logic [4:0]  rd;
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
