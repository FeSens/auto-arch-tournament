// rtl/id_stage.sv
//
// Decode stage. Combinationally drives the regfile read ports and the
// ID/EX register's next-state from the IF/ID combinational bundle plus
// the regfile read data. The ID/EX register is owned by this module so
// the decoded view of instruction n is latched by end of cycle n+1.
//
// Latency:        1 cycle (ID/EX register clocked here).
// RVFI fields:    feeds rs1_addr, rs1_rdata, rs2_addr, rs2_rdata, insn,
//                 trap (via ctrl.is_illegal).
module id_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,
  input  logic              flush,
  input  if_id_t  in,
  // regfile read interface (the read addresses are driven at top level from
  // the un-gated instruction bits, see core.sv)
  input  logic [31:0]       rs1_data,       // bypassed read (RVFI rs1_val only)
  input  logic [31:0]       rs1_raw,        // bypass-free reads ...
  input  logic [31:0]       rs2_raw,
  input  logic              rs1_byp,        // ... and their write-first matches
  input  logic              rs2_byp,
  input  logic [31:0]       wb_data,        // WB-stage write data (the bypass value)
  // bypass matches against the instructions in EX / MEM (forward_unit)
  input  logic              sel1_ex,
  input  logic              sel1_wb,
  input  logic              sel2_ex,
  input  logic              sel2_wb,
  // result of the instruction in MEM (mem_stage.wb_next), captured into the
  // operands when sel*_wb is set
  input  logic [31:0]       wb_next,
  // ID/EX register output
  output id_ex_t  out
);

  // ── Combinational decode ────────────────────────────────────────────────
  logic [4:0]  dec_alu_op;
  logic        dec_alu_src;
  logic [2:0]  dec_branch_op;
  logic        dec_is_branch;
  logic        dec_is_jump;
  logic        dec_is_jalr;
  logic        dec_is_lui;
  logic        dec_is_auipc;
  logic        dec_mem_read;
  logic        dec_mem_write;
  logic [1:0]  dec_mem_width;
  logic        dec_mem_sext;
  logic        dec_reg_write;
  logic        dec_mem_to_reg;
  logic        dec_is_illegal;

  decoder u_decoder (
    .instr      (in.instr),
    .alu_op     (dec_alu_op),
    .alu_src    (dec_alu_src),
    .branch_op  (dec_branch_op),
    .is_branch  (dec_is_branch),
    .is_jump    (dec_is_jump),
    .is_jalr    (dec_is_jalr),
    .is_lui     (dec_is_lui),
    .is_auipc   (dec_is_auipc),
    .mem_read   (dec_mem_read),
    .mem_write  (dec_mem_write),
    .mem_width  (dec_mem_width),
    .mem_sext   (dec_mem_sext),
    .reg_write  (dec_reg_write),
    .mem_to_reg (dec_mem_to_reg),
    .is_illegal (dec_is_illegal)
  );

  logic [31:0] imm;
  imm_gen u_imm (.instr(in.instr), .imm(imm));

  ctrl_t ctrl_decoded;
  always_comb begin
    ctrl_decoded.alu_op     = dec_alu_op;
    ctrl_decoded.alu_src    = dec_alu_src;
    ctrl_decoded.branch_op  = dec_branch_op;
    ctrl_decoded.is_branch  = dec_is_branch;
    ctrl_decoded.is_jump    = dec_is_jump;
    ctrl_decoded.is_jalr    = dec_is_jalr;
    ctrl_decoded.is_lui     = dec_is_lui;
    ctrl_decoded.is_auipc   = dec_is_auipc;
    ctrl_decoded.mem_read   = dec_mem_read;
    ctrl_decoded.mem_write  = dec_mem_write;
    ctrl_decoded.mem_width  = dec_mem_width;
    ctrl_decoded.mem_sext   = dec_mem_sext;
    ctrl_decoded.reg_write  = dec_reg_write;
    ctrl_decoded.mem_to_reg = dec_mem_to_reg;
    ctrl_decoded.is_illegal = dec_is_illegal;
  end

  // ── Operand capture ─────────────────────────────────────────────────────
  // Priority: MEM-stage producer (wb_next) > WB-stage producer (regfile
  // write-first bypass, value wb_data) > regfile. The slow regfile read mux
  // output (rs*_raw) is only selected at the very last 3-input mux: every
  // other source (pc / imm / wb_next / wb_data) is pre-merged into *_early
  // with early selects, and the pc / imm gating is folded into the raw-read
  // select, so the regfile cone ends in a single LUT.
  // ID/EX is only captured while the MEM instruction really completes (no
  // dmem stall, no bubble), so wb_next is valid whenever it is used.
  logic        a_use_rf;
  logic        b_use_rf;
  logic        s_use_rf;
  logic [31:0] a_early;
  logic [31:0] b_early;
  logic [31:0] s_early;
  logic [31:0] op_a_nxt;
  logic [31:0] op_b_nxt;
  logic [31:0] rs2_nxt;

  always_comb begin
    a_use_rf = !dec_is_auipc && !sel1_wb && !rs1_byp;
    b_use_rf = !dec_alu_src  && !sel2_wb && !rs2_byp;
    s_use_rf =                  !sel2_wb && !rs2_byp;

    s_early  = sel2_wb ? wb_next : wb_data;
    a_early  = dec_is_auipc ? in.pc : (sel1_wb ? wb_next : wb_data);
    b_early  = dec_alu_src  ? imm   : s_early;

    op_a_nxt = a_use_rf ? rs1_raw : a_early;
    op_b_nxt = b_use_rf ? rs2_raw : b_early;
    rs2_nxt  = s_use_rf ? rs2_raw : s_early;
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  id_ex_t reg_q;

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      reg_q <= '0;
    end else if (!stall) begin
      reg_q.pc       <= in.pc;
      reg_q.rs1_val  <= rs1_data;
      reg_q.rs2_val  <= rs2_nxt;
      reg_q.imm      <= imm;
      reg_q.rd       <= in.instr[11:7];
      reg_q.rs1_addr <= in.instr[19:15];
      reg_q.rs2_addr <= in.instr[24:20];
      // A bubble F/D slot carries a garbage instruction (no NOP encoding):
      // zero its control bundle so it cannot write the regfile / dmem, be
      // forwarded from, mispredict or trap.
      reg_q.ctrl     <= in.valid ? ctrl_decoded : '0;
      reg_q.instr    <= in.instr;
      reg_q.valid    <= in.valid;
      reg_q.pred_taken  <= in.pred_taken;
      reg_q.pred_target <= in.pred_target;
      reg_q.bht_cnt     <= in.bht_cnt;
      // Pre-muxed ALU operands (MEM-stage result already folded in); the
      // EX bypass selects are off when the operand is pc / imm. flush zeroes
      // them with the rest of ID/EX.
      reg_q.op_a     <= op_a_nxt;
      reg_q.op_b     <= op_b_nxt;
      reg_q.a_ex     <= sel1_ex && !dec_is_auipc;
      reg_q.b_ex     <= sel2_ex && !dec_alu_src;
      reg_q.s_ex     <= sel2_ex;
    end
  end

  assign out = reg_q;

endmodule
