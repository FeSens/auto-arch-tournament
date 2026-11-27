// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// Forwarding select encoding (computed in ID by forward_unit, registered
// in ID/EX as in.fwd_rs1 / in.fwd_rs2 / in.fwd_a / in.fwd_b):
//   00 = ID/EX register value (no forward)
//   01 = EX/MEM aluResult (instruction immediately ahead in MEM)
//   10 = MEM/WB write-back value (instruction two ahead; single register)
//
// The ALU operands have their own 3:1 muxes (in.op_a / in.op_b are already
// pc-or-rs1 / imm-or-rs2), so exactly one mux level sits between the
// forwarding sources and the adder. The adder output is selected in the
// LAST level of the EX/MEM.alu_result mux (in.sel_add, pre-decoded in ID).
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // MEM/WB.alu_result (registered)
  output ex_mem_t  out,
  output logic               ex_w_en,       // post-trap reg_write of the EX instr
  output logic               ex_busy,       // M op in EX, result not ready
  // Registered mispredict / JALR redirect: both are flop outputs, valid in
  // the cycle AFTER the branch left EX (the branch then sits in MEM).
  output logic               redirect,
  output logic [31:0]        redirect_target,
  // Registered PHT training write (flops + one LUT level of counter update)
  output logic               pht_we,
  output logic [7:0]         pht_widx,
  output logic [1:0]         pht_wdata
);

  // redirect flop. While it is 1 the instruction in ID/EX is the single
  // wrong-path instruction that followed the mispredicted branch into EX:
  // it is squashed (EX/MEM bubble, no M-unit start, no redirect / training
  // of its own).
  logic        redir_q;
  logic [31:0] redir_target_q;

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  always_comb begin
    case (in.fwd_rs1)
      2'd1:    rs1 = fwd_ex_mem;
      2'd2:    rs1 = fwd_mem_wb;
      default: rs1 = in.rs1_val;
    endcase
    case (in.fwd_rs2)
      2'd1:    rs2 = fwd_ex_mem;
      2'd2:    rs2 = fwd_mem_wb;
      default: rs2 = in.rs2_val;
    endcase
  end

  // ── ALU operand selection ─────────────────────────────────────────────
  // in.op_a = AUIPC ? pc : rs1_val, in.op_b = alu_src ? imm : rs2_val were
  // muxed in ID; in.fwd_a / in.fwd_b are 00 whenever the operand is not a
  // register value.
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    case (in.fwd_a)
      2'd1:    alu_a = fwd_ex_mem;
      2'd2:    alu_a = fwd_mem_wb;
      default: alu_a = in.op_a;
    endcase
    case (in.fwd_b)
      2'd1:    alu_b = fwd_ex_mem;
      2'd2:    alu_b = fwd_mem_wb;
      default: alu_b = in.op_b;
    endcase
  end

  logic [31:0] alu_add;     // a + b / a - b (late carry chain)
  logic [31:0] alu_other;   // logic / shifts / SLT / LUI
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] alu_full;    // classic merged result — unit tests only
  /* verilator lint_on UNUSEDSIGNAL */
  alu u_alu (
    .op        (in.ctrl.alu_op),
    .a         (alu_a),
    .b         (alu_b),
    .add_out   (alu_add),
    .other_out (alu_other),
    .out       (alu_full)
  );

  // ── Multi-cycle M unit ────────────────────────────────────────────────
  // A valid M op in ID/EX starts the unit on its first EX cycle (the
  // forwarded operands are sampled on that cycle only). While the result
  // is not ready ex_busy holds PC + ID/EX and EX/MEM takes a bubble. The
  // unit parks in `done` until EX/MEM really accepts (!stall), which is
  // the same condition that lets ID/EX advance.
  logic        m_op;
  logic        m_start;
  logic        m_done;
  logic [31:0] m_result;

  // !redir_q: a wrong-path M op behind a mispredicted branch never starts.
  assign m_op = in.valid && (in.ctrl.is_mul || in.ctrl.is_div) && !redir_q;

  muldiv u_muldiv (
    .clock  (clock),
    .reset  (reset),
    .req    (m_op),
    .accept (!stall),
    .f3     (in.instr[14:12]),
    .a      (rs1),
    .b      (rs2),
    .start  (m_start),
    .done   (m_done),
    .result (m_result)
  );

  assign ex_busy = m_op && !m_done;

  // While EX is busy the forwarding sources drain (EX/MEM gets bubbles,
  // MEM/WB moves on), so the forward muxes are only trustworthy on the
  // start cycle. Keep that cycle's rs1/rs2 for the RVFI rs?_rdata fields
  // of the M op (RVFI-only registers: pruned from the timed netlist).
  logic [31:0] m_rs1_q;
  logic [31:0] m_rs2_q;
  always_ff @(posedge clock) begin
    if (m_start) begin
      m_rs1_q <= rs1;
      m_rs2_q <= rs2;
    end
  end

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] jump_target;
  logic [31:0] jalr_sum;  // rs1 + imm: JALR target (bit 0 dropped per RV
                          // spec) and the LOAD/STORE address

  // One equality compare and one unsigned magnitude compare serve all six
  // branch flavours. branch_op = funct3: [2] = magnitude (else equality),
  // [1] = unsigned, [0] = invert. Signed less-than is the unsigned result
  // flipped when the sign bits differ, so the sign fix-up and the invert
  // fold into one early `cmp_flip` bit and only ONE xor/mux level follows
  // the compare chains. branch_op 2/3 never have is_branch set (decoder).
  logic cmp_eq;
  logic cmp_ltu;
  logic cmp_flip;
  // branch_cond != in.pred_taken, with the registered prediction folded
  // into the early invert bits so the depth behind the compare chains is
  // the same single xor/mux level as branch_cond itself.
  logic br_miss;

  always_comb begin
    cmp_eq   = (rs1 == rs2);
    cmp_ltu  = (rs1 < rs2);
    cmp_flip = in.ctrl.branch_op[0]
             ^ (!in.ctrl.branch_op[1] && (rs1[31] != rs2[31]));
    branch_cond = in.ctrl.branch_op[2] ? (cmp_ltu ^ cmp_flip)
                                       : (cmp_eq  ^ in.ctrl.branch_op[0]);
    br_miss     = in.ctrl.branch_op[2]
                ? (cmp_ltu ^ (cmp_flip ^ in.pred_taken))
                : (cmp_eq  ^ (in.ctrl.branch_op[0] ^ in.pred_taken));
    branch_taken  = in.ctrl.is_branch && branch_cond;
    branch_target = in.pc + in.imm;
    // JALR clears bit 0 (RV spec); JAL uses imm directly.
    jalr_sum    = rs1 + in.imm;
    jump_target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0}
                                  : branch_target;
  end

  // ── Misaligned branch / jump target trap ──────────────────────────────
  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, suppress the redirect (PC stays linear), and clear
  // reg_write so JAL/JALR don't write the return address on trap.
  //
  // The alignment of pc+imm (branch / JAL) was decided in ID
  // (in.br_ok / br_bad / jal_bad); only JALR needs an EX-time
  // bit (jalr_sum[1]; bit 0 is cleared by the spec).
  logic misalign_branch;
  logic misalign_jump;
  logic misalign_fault;
  ctrl_t ctrl_with_trap;

  always_comb begin
    misalign_branch = in.br_bad && branch_cond;
    misalign_jump   = in.jal_bad || (in.ctrl.is_jalr && jalr_sum[1]);
    misalign_fault  = misalign_branch || misalign_jump;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
    end
    // Only jumps write a register, so the branch compare stays out of the
    // reg_write (-> ID forwarding select) cone.
    if (misalign_jump) begin
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  assign ex_w_en         = ctrl_with_trap.reg_write;

  // ── Mispredict resolve -> REGISTERED redirect ─────────────────────────
  // if_stage predicted every aligned conditional branch at fetch time
  // (in.pred_taken: PC already went to pc + imm) and folded every aligned
  // JAL. EX only has to correct:
  //   - an aligned branch whose outcome differs from the prediction
  //       predicted taken, not taken  -> pc + 4
  //       predicted not taken, taken  -> pc + imm
  //   - every aligned JALR (never predicted)   -> rs1 + imm, bit 0 cleared
  // A misaligned branch/JAL/JALR target traps and PC stays linear (such a
  // branch is never predicted taken), exactly as before.
  //
  // The compare no longer reaches PC / flush / FIFO valids in its own
  // cycle: it ends in redir_q. The redirect is taken one cycle later, when
  // the branch sits in MEM (never a memory op, so no dmem stall can hold
  // that cycle) and the one wrong-path instruction in EX is squashed.
  logic        mispredict;
  logic [31:0] mp_target;

  always_comb begin
    mispredict = !redir_q
              && ((in.br_ok && br_miss)
               || (in.ctrl.is_jalr && !jalr_sum[1]));
    mp_target  = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0}
               : in.pred_taken   ? (in.pc + 32'd4)
                                 : branch_target;
  end

  always_ff @(posedge clock) begin
    if (reset) redir_q <= 1'b0;
    else       redir_q <= mispredict && !stall;   // only when it moves to MEM
    redir_target_q <= mp_target;
  end

  assign redirect        = redir_q;
  assign redirect_target = redir_target_q;

  // ── PHT training (registered) ─────────────────────────────────────────
  // Once per resolved aligned branch, on the cycle it leaves EX. Index,
  // the counter it was predicted with and the outcome are flopped; the
  // saturating +/-1 happens on the write cycle, so the compare feeds one
  // flop (upd_taken_q) and never the LUT-RAM write port.
  logic       upd_en_q;
  logic       upd_taken_q;
  logic [7:0] upd_idx_q;
  logic [1:0] upd_ctr_q;

  always_ff @(posedge clock) begin
    if (reset) upd_en_q <= 1'b0;
    else       upd_en_q <= in.br_ok && !redir_q && !stall;
    upd_taken_q <= branch_cond;
    upd_idx_q   <= in.pc[9:2];
    upd_ctr_q   <= in.pred_ctr;
  end

  always_comb begin
    pht_we   = upd_en_q;
    pht_widx = upd_idx_q;
    if (upd_taken_q) pht_wdata = (upd_ctr_q == 2'b11) ? 2'b11 : (upd_ctr_q + 2'b01);
    else             pht_wdata = (upd_ctr_q == 2'b00) ? 2'b00 : (upd_ctr_q - 2'b01);
  end

  // ── EX result mux ─────────────────────────────────────────────────────
  // Everything that does not come out of the ALU adder is merged first
  // (JAL/JALR link = pc+4, M-unit result, non-adder ALU result); the
  // adder is selected in the last level by the pre-decoded in.sel_add
  // (= alu_op is ADD/SUB and not a jump; an M op never has sel_add).
  logic [31:0] ex_other;
  logic [31:0] ex_result;
  always_comb begin
    // alu_other is 0 for jumps (alu_op = ADD) and for M ops, so the
    // three sources can simply be OR-ed (flat AND-OR, no priority chain).
    ex_other  = ({32{in.ctrl.is_jump}} & (in.pc + 32'd4))
              | ({32{m_op}}            & m_result);
    ex_result = in.sel_add ? alu_add : (alu_other | ex_other);
  end

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= ex_result;
      reg_q.mem_addr      <= jalr_sum;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= m_op ? m_rs1_q : rs1;
      reg_q.rs2_val       <= m_op ? m_rs2_q : rs2;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect.
      reg_q.pc_next       <= misalign_fault     ? (in.pc + 32'd4)
                            : in.ctrl.is_jump   ? jump_target
                            : branch_taken      ? branch_target
                                                : (in.pc + 32'd4);
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.instr         <= in.instr;
      if (ex_busy || redir_q) begin
        // M op still computing, or the wrong-path instruction behind a
        // mispredicted branch: EX/MEM gets a bubble (no write, no mem
        // op, no retirement). Data fields are don't-care.
        reg_q.ctrl        <= '0;
        reg_q.valid       <= 1'b0;
      end else begin
        reg_q.ctrl        <= ctrl_with_trap;
        reg_q.valid       <= in.valid;
      end
    end
  end

  assign out = reg_q;

endmodule
