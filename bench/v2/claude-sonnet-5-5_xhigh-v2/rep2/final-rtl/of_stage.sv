// rtl/of_stage.sv
//
// Operand-fetch stage. Sits between ID and EX so EX starts at operand
// flops. The instruction in the D/O register (id_ex_t) gets its operands
// forwarded and the operand-independent EX arithmetic computed here, and
// the result is registered in the O/X register (ox_t):
//
//   rs1_v / rs2_v  post-forward rs1 / rs2
//   opa / opb      ALU operands with the select folded in
//                  (opa = is_auipc/is_jump ? pc : rs1,
//                   opb = is_jump ? 4 : alu_src ? imm : rs2)
//   is_md          pre-decoded "alu_op is an M-extension op" flag
//   btgt / pc4 / mp_seq / mp_btgt   pc+imm, pc+4 and the "!= predicted
//                  next PC" compares (depend only on pc/imm/prediction)
//
// Forward sources, priority high to low (select flags from forward_unit,
// flop-fed compares only):
//   dist 1  instruction in EX:  x_result (combinational, late)
//   dist 2  instruction in MEM: m_result (load data / ALU result)
//   dist 3  instruction in WB:  MEM/WB wb_data flop
//   else    D/O rs?_val (regfile read; covers every older producer)
//
// The late EX result crosses exactly ONE LUT: operand_d = sel1 ? x_result
// : early, where `early` (including the late-ish m_result) is built in
// parallel with the compares.
//
// Hold / bubble: the O/X register holds on dmem_stall / muldiv busy and
// captures a bubble on load-use / redirect (see hazard_unit). Only valid,
// ctrl and rd are cleared by a bubble: every consumer of the data fields
// is gated by them, so the wide data path has no sync-reset net.
//
// Latency:        1 cycle (O/X register clocked here).
// RVFI fields:    carries pc, instr, rs addrs, valid down the pipe; rs1_v /
//                 rs2_v become rs1_rdata / rs2_rdata.
module of_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              hold,       // O/X holds (dmem stall / muldiv busy)
  input  logic              bubble,     // O/X captures a bubble
  input  id_ex_t            in,         // D/O register
  // dist 1: instruction in EX
  input  logic [31:0]       x_result,
  input  logic              x_reg_write,  // post-trap
  // dist 2: instruction in MEM
  input  logic [31:0]       m_result,
  input  logic [4:0]        m_rd,
  input  logic              m_reg_write,  // post-trap
  // dist 3: instruction in WB (MEM/WB wb_data flop)
  input  logic [31:0]       w_data,
  input  logic [4:0]        w_rd,
  input  logic              w_reg_write,
  // O/X register output
  output ox_t               out
);

  ox_t reg_q;

  // ── Forward selects (flop-fed compares) ────────────────────────────────
  logic [2:0] fwd1;
  logic [2:0] fwd2;

  forward_unit u_fwd (
    .of_rs1   (in.rs1_addr),
    .of_rs2   (in.rs2_addr),
    .ex_rd    (reg_q.rd),
    .ex_w_en  (x_reg_write),
    .mem_rd   (m_rd),
    .mem_w_en (m_reg_write),
    .wb_rd    (w_rd),
    .wb_w_en  (w_reg_write),
    .fwd_rs1  (fwd1),
    .fwd_rs2  (fwd2)
  );

  // ── Operand muxes ──────────────────────────────────────────────────────
  logic [31:0] early1, early2;      // rs1 / rs2 without the dist-1 forward
  logic [31:0] early_a, early_b;    // ... with the opa / opb select folded in
  logic        sel_a, sel_b;        // dist-1 forward into opa / opb
  logic [31:0] rs1_d, rs2_d, opa_d, opb_d;

  always_comb begin
    early1  = fwd1[1] ? m_result : fwd1[2] ? w_data : in.rs1_val;
    early2  = fwd2[1] ? m_result : fwd2[2] ? w_data : in.rs2_val;
    // JAL/JALR send pc + 4 (the link address) through the ALU: rs1 / rs2 are
    // consumed only by jalr_sum and the compare, never by opa / opb.
    early_a = (in.ctrl.is_auipc || in.ctrl.is_jump) ? in.pc  : early1;
    early_b = in.ctrl.is_jump ? 32'd4 : in.ctrl.alu_src ? in.imm : early2;
    sel_a   = fwd1[0] && !in.ctrl.is_auipc && !in.ctrl.is_jump;
    sel_b   = fwd2[0] && !in.ctrl.alu_src  && !in.ctrl.is_jump;

    rs1_d   = fwd1[0] ? x_result : early1;
    rs2_d   = fwd2[0] ? x_result : early2;
    opa_d   = sel_a   ? x_result : early_a;
    opb_d   = sel_b   ? x_result : early_b;
  end

  // ── Operand-independent EX arithmetic ──────────────────────────────────
  logic [31:0] pc4_d;
  logic [31:0] btgt_d;
  logic [31:0] pred_full;
  logic        mp_seq_d;
  logic        mp_btgt_d;

  always_comb begin
    pc4_d     = in.pc + 32'd4;
    btgt_d    = in.pc + in.imm;
    pred_full = in.pred_taken ? {12'b0, in.pred_npc, 2'b00} : pc4_d;
    mp_seq_d  = (pc4_d  != pred_full);
    mp_btgt_d = (btgt_d != pred_full);
  end

  // ── O/X register ───────────────────────────────────────────────────────
  // Data fields: captured whenever the register advances (a bubble's data
  // is don't-care: valid / ctrl / rd are cleared below).
  always_ff @(posedge clock) begin
    if (!hold) begin
      reg_q.pc         <= in.pc;
      reg_q.rs1_v      <= rs1_d;
      reg_q.rs2_v      <= rs2_d;
      reg_q.opa        <= opa_d;
      reg_q.opb        <= opb_d;
      reg_q.imm        <= in.imm;
      reg_q.rs1_addr   <= in.rs1_addr;
      reg_q.rs2_addr   <= in.rs2_addr;
      reg_q.instr      <= in.instr;
      reg_q.pred_taken <= in.pred_taken;
      reg_q.pred_npc   <= in.pred_npc;
      reg_q.pred_hit   <= in.pred_hit;
      reg_q.pred_ctr   <= in.pred_ctr;
      reg_q.btgt       <= btgt_d;
      reg_q.pc4        <= pc4_d;
      reg_q.mp_seq     <= mp_seq_d;
      reg_q.mp_btgt    <= mp_btgt_d;
    end
  end

  // Control: cleared by reset / bubble so a bubble is inert everywhere
  // (no forward, no mem op, no mispredict, no BTB training, no retirement).
  always_ff @(posedge clock) begin
    if (reset || bubble) begin
      reg_q.valid <= 1'b0;
      reg_q.ctrl  <= '0;
      reg_q.is_md <= 1'b0;
      reg_q.rd    <= 5'b0;
    end else if (!hold) begin
      reg_q.valid <= in.valid;
      reg_q.ctrl  <= in.ctrl;
      reg_q.is_md <= (in.ctrl.alu_op >= ALU_MUL) && (in.ctrl.alu_op <= ALU_REMU);
      reg_q.rd    <= in.rd;
    end
  end

  assign out = reg_q;

endmodule
