// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand mux (forwarding from EX/MEM), runs
// the ALU, checks the front end's branch/jump prediction and owns the
// EX/MEM pipeline register.
//
// Mispredict recovery is *registered*: when a branch/JALR that advances out
// of EX turns out to have been mispredicted (direction wrong, unpredicted
// JALR, or RAS target mismatch), {kill, kill_target} are latched. During the
// following cycle `kill` is high: the (wrong-path) instruction in EX becomes
// a bubble, the instruction in F/D is dropped and the PC is loaded from
// kill_target. No combinational redirect leaves this stage; the only late
// EX->control signal is the D pin of the kill flop. If a dmem stall freezes
// the pipeline while kill is high, kill is held until the stall ends.
//
// M-extension ops are executed by the sequential MDU (mdu.sv), not the
// ALU. An M-op stays in EX until the MDU reports `done` (mdu_stall holds
// the PC and ID/EX in the hazard unit); meanwhile EX/MEM captures bubbles
// so MEM and WB keep draining older instructions.
//
// Forwarding is resolved in ID: forward_unit compares the consumer's
// rs1/rs2 with the producers in EX / MEM one cycle early. The MEM-stage
// producer's result is captured straight into the ID/EX operands by
// id_stage, so EX only has one forward leg: the instruction that was in EX
// when the consumer was in ID, now in EX/MEM. ID/EX carries select flags
// (a_ex, b_ex, s_ex); each is gated here with the producer's registered
// reg_write (trap-cancel exactness: a misaligned JAL/JALR clears reg_write
// after the select was registered), so one LUT4 per bit:
//   a_in  = fwd(op_a)    ALU a (rs1 or pc), branch/jalr/MDU rs1
//   b_in  = fwd(op_b)    ALU b (rs2 or imm)
//   s_in  = fwd(rs2_val) raw rs2: branch compare, store data, MDU b
// The ID-stage operand muxes (is_auipc / alu_src) are already folded into
// op_a / op_b. The legacy combinational compare (fwd_rs1_sel) only feeds
// the RVFI rs1_rdata report and is pruned from the timed netlist.
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  input  logic [1:0]         fwd_rs1_sel,   // legacy compare (RVFI rs1 only)
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // MEM/WB.wb_data (RVFI rs1 only)
  output ex_mem_t  out,
  output logic               kill,          // registered mispredict recovery
  output logic [31:0]        kill_target,   // corrected PC for the recovery
  // BHT update (valid only for a branch advancing out of EX)
  output logic               bht_upd_valid,
  output logic [7:0]         bht_upd_idx,
  output logic               bht_upd_taken,
  output logic [1:0]         bht_upd_cnt,
  output logic               mdu_stall      // M-op in EX, result not ready
);

  ex_mem_t reg_q;   // EX/MEM register (written at the bottom of the module)

  // ── Operand forwarding (registered one-hot selects) ───────────────────
  logic ex_rw;   // EX/MEM producer still writes the regfile (registered)
  logic [31:0] a_in;
  logic [31:0] b_in;
  logic [31:0] s_in;

  assign ex_rw = reg_q.ctrl.reg_write;

  logic a_use_ex, b_use_ex, s_use_ex;
  always_comb begin
    a_use_ex = in.a_ex && ex_rw;
    b_use_ex = in.b_ex && ex_rw;
    s_use_ex = in.s_ex && ex_rw;

    a_in = a_use_ex ? fwd_ex_mem : in.op_a;
    b_in = b_use_ex ? fwd_ex_mem : in.op_b;
    s_in = s_use_ex ? fwd_ex_mem : in.rs2_val;
  end

  // RVFI-only rs1 report: legacy compare on the ID/EX rs1 address. For
  // AUIPC a_in carries pc, so the reported rs1 value needs its own path.
  logic [31:0] rs1_rvfi;
  always_comb begin
    case (fwd_rs1_sel)
      2'd1:    rs1_rvfi = fwd_ex_mem;
      2'd2:    rs1_rvfi = fwd_mem_wb;
      default: rs1_rvfi = in.rs1_val;
    endcase
  end

  // Dedicated address-generation adder: LOAD/STORE always have alu_src=1 and
  // is_auipc=0, so a_in + imm is exactly what the ALU's ALU_ADD would give,
  // without the result mux / link mux / MDU merge in front of the flop.
  logic [31:0] agu_sum;
  assign agu_sum = a_in + in.imm;

  logic [31:0] alu_result;
  alu u_alu (
    .op  (in.ctrl.alu_op),
    .a   (a_in),
    .b   (b_in),
    .out (alu_result)
  );

  // ── MDU (M-extension) ─────────────────────────────────────────────────
  // The MDU samples the forward-resolved rs1/rs2 on its first EX cycle and
  // keeps its own copy afterwards (the forwarding sources have drained by
  // then). mdu_done is a pure function of the MDU state register.
  logic        is_mdu;
  logic        mdu_busy;
  logic        mdu_done;
  logic [31:0] mdu_result;
  logic [31:0] mdu_a;
  logic [31:0] mdu_b;

  // A wrong-path M-op (kill high) must neither start the MDU nor stall.
  assign is_mdu    = in.valid && !kill && (in.ctrl.alu_op >= ALU_MUL);
  assign mdu_stall = is_mdu && !mdu_done;

  mdu u_mdu (
    .clock  (clock),
    .reset  (reset),
    .active (is_mdu),
    .op     (in.ctrl.alu_op),
    .a      (a_in),
    .b      (s_in),
    .hold   (stall),
    .busy   (mdu_busy),
    .done   (mdu_done),
    .result (mdu_result),
    .a_cap  (mdu_a),
    .b_cap  (mdu_b)
  );

  // Operands reported on EX/MEM (RVFI rs1/rs2_rdata, store data): while the
  // M-op waits in EX after its first cycle the fwd muxes no longer see the
  // producer, so use the MDU's captured copy.
  logic [31:0] rs1_out;
  logic [31:0] rs2_out;
  always_comb begin
    rs1_out = mdu_busy ? mdu_a : rs1_rvfi;
    rs2_out = mdu_busy ? mdu_b : s_in;
  end

  // The ALU yields 0 for M opcodes, so the MDU result (gated to 0 for
  // everything else) is merged with a plain OR instead of another mux.
  logic [31:0] ex_result;
  assign ex_result = alu_result | (is_mdu ? mdu_result : 32'b0);

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] jump_target;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] jalr_sum;  // bit 0 deliberately dropped per RV JALR spec
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    case (in.ctrl.branch_op)
      BR_BEQ:  branch_cond = (a_in == s_in);
      BR_BNE:  branch_cond = (a_in != s_in);
      BR_BLT:  branch_cond = ($signed(a_in) <  $signed(s_in));
      BR_BGE:  branch_cond = ($signed(a_in) >= $signed(s_in));
      BR_BLTU: branch_cond = (a_in <  s_in);
      BR_BGEU: branch_cond = (a_in >= s_in);
      default: branch_cond = 1'b0;
    endcase
    branch_taken  = in.ctrl.is_branch && branch_cond;
    branch_target = in.pc + in.imm;
    // JALR clears bit 0 (RV spec); JAL uses imm directly.
    jalr_sum    = a_in + in.imm;
    jump_target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0}
                                  : (in.pc + in.imm);
  end

  // ── Misaligned branch / jump target trap ──────────────────────────────
  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, suppress the redirect (PC stays linear), and clear
  // reg_write so JAL/JALR don't write the return address on trap.
  logic misalign_branch;
  logic misalign_jump;
  logic misalign_fault;
  ctrl_t ctrl_with_trap;

  always_comb begin
    misalign_branch = in.ctrl.is_branch && branch_taken
                      && (branch_target[1:0] != 2'b00);
    misalign_jump   = in.ctrl.is_jump && (jump_target[1:0] != 2'b00);
    misalign_fault  = misalign_branch || misalign_jump;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  // ── Prediction check / registered recovery ────────────────────────────
  // The front end followed `pred_target` iff in.pred_taken (otherwise pc+4).
  //   BRANCH : mispredict when the direction differs. A predicted-taken
  //            branch never has a misaligned target (predecode rejects
  //            those); an unpredicted taken branch with a misaligned target
  //            traps and the front end already went to pc+4.
  //   JAL    : predicted taken unless its target is misaligned or out of the
  //            predictor's range; an unpredicted aligned JAL redirects to
  //            pc+imm, a misaligned one traps (front end already at pc+4).
  //   JALR   : only a `ret` matching the RAS target (a_in == pred_target) is
  //            correct. A misaligned unpredicted JALR traps with no redirect;
  //            a misaligned predicted one fails the RAS compare and
  //            recovers to pc+4.
  logic [31:0] pc_plus4;
  logic        jalr_hit;
  logic        mispredict;
  logic [31:0] recover_target;

  always_comb begin
    pc_plus4 = in.pc + 32'd4;
    jalr_hit = in.pred_taken && (a_in == {in.pred_target, 2'b00});

    if (in.ctrl.is_branch)
      mispredict = (branch_cond != in.pred_taken) && !misalign_branch;
    else if (in.ctrl.is_jalr)
      mispredict = !jalr_hit && !(jalr_sum[1] && !in.pred_taken);
    else if (in.ctrl.is_jump)
      mispredict = !in.pred_taken && !misalign_jump;
    else
      mispredict = 1'b0;

    // Early-selected correct-path target.
    if (in.ctrl.is_jalr)
      recover_target = jalr_sum[1] ? pc_plus4 : {jalr_sum[31:2], 2'b00};
    else
      recover_target = in.pred_taken ? pc_plus4 : branch_target;
  end

  // New recovery only when the instruction really leaves EX this cycle and
  // is not itself wrong-path.
  logic kill_q;
  logic [31:0] kill_target_q;
  logic ex_adv;

  assign ex_adv = !stall && !mdu_stall;

  always_ff @(posedge clock) begin
    if (reset) kill_q <= 1'b0;
    else       kill_q <= (!kill_q && ex_adv && in.valid && mispredict)
                      || (kill_q && stall);
    if (!kill_q) kill_target_q <= recover_target;
  end

  assign kill        = kill_q;
  assign kill_target = kill_target_q;

  // BHT update strobe for a (non-wrong-path) branch leaving EX.
  assign bht_upd_valid = ex_adv && in.valid && !kill_q && in.ctrl.is_branch;
  assign bht_upd_idx   = in.pc[9:2];
  assign bht_upd_taken = branch_cond;
  assign bht_upd_cnt   = in.bht_cnt;

  // ── EX/MEM register ───────────────────────────────────────────────────
  // Split into a control block (ctrl, valid) and a data block. Only the
  // control block sees reset / bubble clearing; every consumer of the data
  // fields is gated by the registered ctrl / valid, so the data flops only
  // need the dmem-stall clock enable (no reset, no bubble clear).
  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q.ctrl  <= '0;
      reg_q.valid <= 1'b0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q.ctrl  <= reg_q.ctrl;
      reg_q.valid <= reg_q.valid;
    end else if (mdu_stall || kill_q) begin
      // M-op still executing in the MDU: inject a bubble so MEM/WB keep
      // draining older instructions. A wrong-path instruction (kill) is
      // dropped the same way.
      reg_q.ctrl  <= '0;
      reg_q.valid <= 1'b0;
    end else begin
      reg_q.ctrl  <= ctrl_with_trap;
      reg_q.valid <= in.valid;
    end
  end

  always_ff @(posedge clock) begin
    if (!stall) begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= in.ctrl.is_jump ? (in.pc + 32'd4) : ex_result;
      // LOAD/STORE effective address straight from the dedicated AGU adder.
      reg_q.mem_addr      <= agu_sum;
      reg_q.write_data    <= rs2_out;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= rs1_out;
      reg_q.rs2_val       <= rs2_out;
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
    end
  end

  assign out = reg_q;

endmodule
