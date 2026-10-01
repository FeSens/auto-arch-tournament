// rtl/id_stage.sv
//
// Decode stage. Combinationally drives the regfile read ports and the
// ID/EX register's next-state from the IF/ID combinational bundle plus
// the regfile read data. The ID/EX register is owned by this module so
// the decoded view of instruction n is latched by end of cycle n+1.
//
// The bypass network lives here (VexRiscv style): ID/EX.rs1_val/rs2_val
// capture fully-forwarded operands, so every EX lane starts from a plain
// flop.
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
  // regfile read interface
  output logic [4:0]        rs1_addr,
  output logic [4:0]        rs2_addr,
  input  logic [31:0]       rs1_data,
  input  logic [31:0]       rs2_data,
  // Bypass sources (see forward_unit.sv). ex_result is the late one and
  // sits at the last mux level before the ID/EX operand flops.
  input  logic [31:0]       ex_result,     // EX one-hot result (-> EX/MEM.alu_result)
  input  logic              ex_w_en,       // ID/EX reg_write, trap-cleared
  input  logic [4:0]        ex_mem_rd,
  input  logic [31:0]       mem_fwd_data,  // EX/MEM non-load value (alu_or_mul)
  input  logic [31:0]       mem_load_data, // EX/MEM load value (MEM load extract)
  input  logic              mem_is_load,   // EX/MEM.ctrl.mem_to_reg
  input  logic              mem_fwd_w_en,  // EX/MEM reg_write, trap-cleared
  input  logic [4:0]        mem_wb_rd,
  input  logic [31:0]       wb_w_data,     // MEM/WB write-back value
  input  logic              wb_w_en,       // MEM/WB reg_write && valid
  // Branch prediction for the IF word (branch_pred.sv). pc_imm is the
  // predicted target (shared imm_gen / pc + imm adder).
  input  logic              pred,
  input  logic [1:0]        pred_ctr,
  output logic [31:0]       pc_imm,
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

  // Regfile read addresses come straight from the IF/ID instruction — these
  // are also wired to the hazard unit at top level for load-use detection.
  assign rs1_addr = in.instr[19:15];
  assign rs2_addr = in.instr[24:20];

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
    // Registered into ID/EX so the EX-stage divider stall (ex_busy) comes
    // straight from a pipeline flop.
    ctrl_decoded.is_div     = (dec_alu_op == ALU_DIV)  || (dec_alu_op == ALU_DIVU) ||
                              (dec_alu_op == ALU_REM)  || (dec_alu_op == ALU_REMU);
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  id_ex_t reg_q;

  // ── Operand-independent precompute ──────────────────────────────────────
  // pc + imm serves as branch/JAL target and the AUIPC result; pc + 4 is
  // the JAL/JALR link value. EX merges pre_result at its late result mux.
  logic [31:0] pc4;
  logic [31:0] pre_result;
  logic        sel_pre;
  logic        sel_div;
  always_comb begin
    pc_imm     = in.pc + imm;
    pc4        = in.pc + 32'd4;
    pre_result = dec_is_lui   ? imm
               : dec_is_auipc ? pc_imm
                              : pc4;
    sel_pre    = dec_is_lui || dec_is_auipc || dec_is_jump;
    sel_div    = ctrl_decoded.is_div;
  end

  // ── Mispredict "redirect-when" flags ────────────────────────────────────
  // A branch predicted not-taken redirects when its condition holds, one
  // predicted taken when it fails. A taken target with imm[1] = 1 traps
  // (pc is 4-aligned, so imm[1] is the target misalignment) and keeps the
  // PC linear, so such a branch never redirects toward taken (it is also
  // never predicted). JAL is predicted whenever it is aligned; f_jal
  // covers an unpredicted aligned JAL for completeness. EX redirects to
  // alt_target (or the JALR target) iff a flagged condition holds.
  logic [2:0]  f3;
  logic        take_ok;
  logic        f_eq, f_ne, f_lt, f_ge, f_ltu, f_geu, f_jal, f_jr;
  logic [31:0] alt_target;
  always_comb begin
    f3         = in.instr[14:12];
    take_ok    = !pred && !imm[1];
    f_eq       = dec_is_branch && ((f3 == BR_BEQ  && take_ok) || (f3 == BR_BNE  && pred));
    f_ne       = dec_is_branch && ((f3 == BR_BNE  && take_ok) || (f3 == BR_BEQ  && pred));
    f_lt       = dec_is_branch && ((f3 == BR_BLT  && take_ok) || (f3 == BR_BGE  && pred));
    f_ge       = dec_is_branch && ((f3 == BR_BGE  && take_ok) || (f3 == BR_BLT  && pred));
    f_ltu      = dec_is_branch && ((f3 == BR_BLTU && take_ok) || (f3 == BR_BGEU && pred));
    f_geu      = dec_is_branch && ((f3 == BR_BGEU && take_ok) || (f3 == BR_BLTU && pred));
    f_jal      = dec_is_jump && !dec_is_jalr && take_ok;
    f_jr       = dec_is_jalr;
    alt_target = pred ? pc4 : pc_imm;
  end

  // One-hot ALU lane selects. AUIPC and JAL(R) decode as ADD but ride
  // pre_result, so the base lanes are masked by sel_pre; M ops and LUI
  // decode to all-zero base lanes.
  logic       l_add, l_sub, l_sll, l_sr, l_arith, l_slt, l_sltu;
  logic [1:0] l_lop;
  logic       l_mul_lo, l_mul_hi, l_mul_sa, l_mul_sb;
  alu_dec u_alu_dec (
    .op       (dec_alu_op),
    .sel_add  (l_add),
    .sub      (l_sub),
    .lop      (l_lop),
    .sel_sll  (l_sll),
    .sel_sr   (l_sr),
    .sh_arith (l_arith),
    .sel_slt  (l_slt),
    .slt_u    (l_sltu),
    .mul_lo   (l_mul_lo),
    .mul_hi   (l_mul_hi),
    .mul_sa   (l_mul_sa),
    .mul_sb   (l_mul_sb)
  );

  // ── Bypass network (ID side) ────────────────────────────────────────────
  // Priority ex > mem > wb > rf; the selects depend only on IF-instr bits
  // and stage rd/ctrl flops, and ex_result enters at the last level so
  // the EX cone ends one LUT before the ID/EX operand flops.
  logic sel1_ex, sel1_mem, sel1_wb, sel2_ex, sel2_mem, sel2_wb;
  forward_unit u_fwd (
    .rs1      (in.instr[19:15]),
    .rs2      (in.instr[24:20]),
    .ex_rd    (reg_q.rd),
    .ex_w_en  (ex_w_en),
    .mem_rd   (ex_mem_rd),
    .mem_w_en (mem_fwd_w_en),
    .wb_rd    (mem_wb_rd),
    .wb_w_en  (wb_w_en),
    .sel1_ex  (sel1_ex),
    .sel1_mem (sel1_mem),
    .sel1_wb  (sel1_wb),
    .sel2_ex  (sel2_ex),
    .sel2_mem (sel2_mem),
    .sel2_wb  (sel2_wb)
  );

  // The two late data sources, ex_result and the MEM-stage load value,
  // both enter at the last level; sel?_ld is built on the select side
  // only (a LOAD/MUL in EX never gets here: load/mul-use interlock).
  logic        sel1_ld, sel2_ld;
  logic [31:0] rs1_early, rs2_early;
  logic [31:0] rs1_fwd, rs2_fwd;
  logic        mul_a_sx, mul_b_sx;
  always_comb begin
    sel1_ld   = sel1_mem && mem_is_load;
    sel2_ld   = sel2_mem && mem_is_load;
    rs1_early = sel1_mem ? mem_fwd_data : sel1_wb ? wb_w_data : rs1_data;
    rs2_early = sel2_mem ? mem_fwd_data : sel2_wb ? wb_w_data : rs2_data;
    rs1_fwd   = sel1_ex  ? ex_result : sel1_ld ? mem_load_data : rs1_early;
    rs2_fwd   = sel2_ex  ? ex_result : sel2_ld ? mem_load_data : rs2_early;
    // Multiplier operand extension bits (sign bit of the forwarded value
    // for the signed operands), folded into the bit-31 forward LUT.
    mul_a_sx  = l_mul_sa && rs1_fwd[31];
    mul_b_sx  = l_mul_sb && rs2_fwd[31];
  end

  // Flush clears only valid, ctrl and the lane selects (a bubble's data
  // fields are never observed). The data fields capture on !stall alone,
  // so flush_id (and the redirect behind it) never reaches their enables.
  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else begin
      if (!stall) begin
        reg_q.pc            <= in.pc;
        reg_q.rs1_val       <= rs1_fwd;
        reg_q.rs2_val       <= rs2_fwd;
        reg_q.imm           <= imm;
        reg_q.rd            <= in.instr[11:7];
        reg_q.rs1_addr      <= in.instr[19:15];
        reg_q.rs2_addr      <= in.instr[24:20];
        reg_q.instr         <= in.instr;
        reg_q.pre_result    <= pre_result;
        reg_q.branch_target <= pc_imm;
        reg_q.mul_a_sx      <= mul_a_sx;
        reg_q.mul_b_sx      <= mul_b_sx;
        // Lane controls other than the result selects are don't-care
        // when their lane is off.
        reg_q.sub           <= l_sub;
        reg_q.sh_arith      <= l_arith;
        reg_q.slt_u         <= l_sltu;
        reg_q.ctr           <= pred_ctr;
        reg_q.alt_target    <= alt_target;
      end
      if (flush) begin
        reg_q.ctrl        <= '0;
        reg_q.valid       <= 1'b0;
        reg_q.sel_add     <= 1'b0;
        reg_q.lop         <= 2'b00;
        reg_q.sel_sll     <= 1'b0;
        reg_q.sel_sr      <= 1'b0;
        reg_q.sel_slt     <= 1'b0;
        reg_q.sel_div     <= 1'b0;
        reg_q.sel_pre     <= 1'b0;
        reg_q.sel_mul_lo  <= 1'b0;
        reg_q.sel_mul_hi  <= 1'b0;
        reg_q.late_result <= 1'b0;
        reg_q.f_eq        <= 1'b0;
        reg_q.f_ne        <= 1'b0;
        reg_q.f_lt        <= 1'b0;
        reg_q.f_ge        <= 1'b0;
        reg_q.f_ltu       <= 1'b0;
        reg_q.f_geu       <= 1'b0;
        reg_q.f_jal       <= 1'b0;
        reg_q.f_jr        <= 1'b0;
      end else if (!stall) begin
        reg_q.ctrl        <= ctrl_decoded;
        reg_q.valid       <= in.valid;
        reg_q.sel_add     <= l_add && !sel_pre;
        reg_q.lop         <= sel_pre ? 2'b00 : l_lop;
        reg_q.sel_sll     <= l_sll;
        reg_q.sel_sr      <= l_sr;
        reg_q.sel_slt     <= l_slt;
        reg_q.sel_div     <= sel_div;
        reg_q.sel_pre     <= sel_pre;
        reg_q.sel_mul_lo  <= l_mul_lo;
        reg_q.sel_mul_hi  <= l_mul_hi;
        reg_q.late_result <= dec_mem_read || l_mul_lo || l_mul_hi;
        reg_q.f_eq        <= f_eq;
        reg_q.f_ne        <= f_ne;
        reg_q.f_lt        <= f_lt;
        reg_q.f_ge        <= f_ge;
        reg_q.f_ltu       <= f_ltu;
        reg_q.f_geu       <= f_geu;
        reg_q.f_jal       <= f_jal;
        reg_q.f_jr        <= f_jr;
      end
    end
  end

  assign out = reg_q;

endmodule
