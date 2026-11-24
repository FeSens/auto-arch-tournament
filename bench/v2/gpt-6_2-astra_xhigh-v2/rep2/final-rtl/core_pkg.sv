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
    logic       late_result; // M-extension result, first forwardable from MEM/WB
    logic       is_illegal;  // default-true in decoder; cleared inside
                              // validated opcode/funct arms only.
  } ctrl_t;

  // IF -> ID combinational bundle for the current instruction bus address.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
    logic        valid;
  } if_id_t;

  // ID/EX register payload.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
    logic [31:0] imm;
    logic [31:0] mem_addr;
    logic        page_cross;
    logic        base_available;
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
    logic        forwardable;    // trap-checked EX result available to the next EX slot
    logic [31:0] mem_addr;       // serviced byte address
    logic [31:0] mem_rdata;      // raw word sampled on the accepting edge
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
    logic [31:0] alu_result;
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

  function automatic logic [3:0] access_mask(input logic [1:0] width, offset);
    case (width)
      2'd0:    access_mask = 4'b0001 << offset;
      2'd1:    access_mask = 4'b0011 << offset;
      default: access_mask = 4'b1111;
    endcase
  endfunction

  function automatic logic [31:0] store_lanes(input logic [1:0] width,
                                               input logic [31:0] data);
    case (width)
      2'd0:    store_lanes = {4{data[7:0]}};
      2'd1:    store_lanes = {2{data[15:0]}};
      default: store_lanes = data;
    endcase
  endfunction

`endif // CORE_PKG_DEFINED
