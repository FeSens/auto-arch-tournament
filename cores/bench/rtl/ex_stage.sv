// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches and checks IF's fetch-time
// prediction. Owns the EX/MEM pipeline register.
//
// Prediction check: IF already steered the PC for a predicted BRANCH/JAL
// (in.pred_taken), so redirect fires only on a mispredict, i.e. when
// the real outcome differs from the prediction, plus every JALR (never
// predicted). The mispredict target is in.alt_target, the path IF did
// not take, so the EX pc+imm adder is off the redirect path; only JALR
// uses its forwarded sum. The BHT update (counter inc/dec by the branch
// condition) is registered here and written into IF one cycle later, so
// the forwarded compare never reaches the BHT write enables.
//
// Late branch (in.late, see id_stage.sv): arrives with is_branch and
// pred_taken 0, so it never redirects, traps or writes the BHT here. Its
// load operand's forward (EX/MEM = the LOAD's address) is meaningless;
// MEM substitutes MEM/WB.read_data. EX only carries the late fields into
// EX/MEM. The other operand forwards as usual (its rs does not match the
// LOAD's rd).
//
// late_kill (a WB-stage flop from mem_stage: a late branch mispredicted)
// is ORed into redirect with late_tgt as the target, and kills this
// stage's instruction: EX/MEM captures a bubble, the div_unit returns to
// IDLE, and no BHT write is registered.
//
// Forwarding select encoding (driven by forward_unit):
//   00 = ID/EX register value (no forward)
//   01 = EX/MEM aluResult (instruction immediately ahead in MEM)
//   10 = MEM/WB result (instruction two ahead, post regfile-write mux)
//
// DIV/DIVU/REM/REMU (ctrl.is_div) run in the multi-cycle div_unit:
//   - first EX cycle: the unit latches the post-forward rs1/rs2 and starts.
//     Those latched values are also what RVFI reports as rs1/rs2_rdata,
//     since the forwarding sources drain while the divide waits.
//   - while busy (ex_div_busy): hazard_unit holds PC + ID/EX, and EX/MEM
//     captures a bubble (valid=0, reg_write=0) on every non-stall cycle,
//     so older instructions retire exactly once.
//   - done (sticky until !stall): EX/MEM captures the divide with its
//     registered result, and ID/EX advances on the same edge.
//
// Latency:        1 cycle (EX/MEM register clocked here); divides hold
//                 EX for the div_unit latency. BHT write 1 cycle after EX.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU, divide and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic                  clock,
  input  logic                  reset,
  input  logic                  stall,         // freeze EX/MEM register (dmem stall)
  // in.ld_nz is for the hazard unit only.
  /* verilator lint_off UNUSEDSIGNAL */
  input  id_ex_t   in,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [1:0]            fwd_rs1_sel,
  input  logic [1:0]            fwd_rs2_sel,
  input  logic [31:0]           fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]           fwd_mem_wb,    // WB-stage write-data mux output
  // Late-branch mispredict in WB (registered in MEM) and its target
  input  logic                  late_kill,
  input  logic [31:0]           late_tgt,
  output ex_mem_t  out,
  // Raw ALU result: the load/store address EX/MEM captures next edge.
  // Feeds only mem_stage's registered cache lookahead.
  output logic [31:0]           ex_addr,
  output logic                  redirect,      // mispredict / JALR, or late_kill
  output logic [31:0]           redirect_target,
  output logic                  ex_div_busy,   // divide in EX, result not ready
  // Registered BHT update into IF
  output logic                  bht_we,
  output logic [BHT_IDX_W-1:0]  bht_widx,
  output logic [1:0]            bht_wdata
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  always_comb begin
    case (fwd_rs1_sel)
      2'd1:    rs1 = fwd_ex_mem;
      2'd2:    rs1 = fwd_mem_wb;
      default: rs1 = in.rs1_val;
    endcase
    case (fwd_rs2_sel)
      2'd1:    rs2 = fwd_ex_mem;
      2'd2:    rs2 = fwd_mem_wb;
      default: rs2 = in.rs2_val;
    endcase
  end

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    alu_a = in.ctrl.is_auipc ? in.pc  : rs1;
    alu_b = in.ctrl.alu_src  ? in.imm : rs2;
  end

  // The ALU runs from the one-hot controls pre-decoded in ID (in.alu_ctl),
  // so no opcode decode sits between ID/EX and EX/MEM.
  logic [31:0] alu_result;
  alu_core u_alu (
    .ctl (in.alu_ctl),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result)
  );

  assign ex_addr = alu_result;

  // ── Multi-cycle divide unit ───────────────────────────────────────────
  // start is only accepted while the unit is idle, i.e. on the divide's
  // first EX cycle (the unit returns to idle on the same edge EX/MEM
  // takes the result and ID/EX moves on). funct3[1] = REM, funct3[0] =
  // unsigned. A divide never branches, jumps, or touches memory.
  // late_kill (the divide is wrong-path) sends the unit back to IDLE, so
  // an orphaned divide can never hand its result to a later one.
  logic        div_req;
  logic        div_done;
  logic [31:0] div_q;
  logic [31:0] div_rs1_q;
  logic [31:0] div_rs2_q;

  assign div_req     = in.valid && in.ctrl.is_div;
  assign ex_div_busy = div_req && !div_done;

  div_unit u_div (
    .clock       (clock),
    .reset       (reset),
    .start       (div_req),
    .ack         (div_done && !stall),
    .kill        (late_kill),
    .is_rem      (in.instr[13]),
    .is_unsigned (in.instr[12]),
    .a           (rs1),
    .b           (rs2),
    /* verilator lint_off PINCONNECTEMPTY */
    .busy        (),
    /* verilator lint_on PINCONNECTEMPTY */
    .done        (div_done),
    .result      (div_q),
    .a_lat       (div_rs1_q),
    .b_lat       (div_rs2_q)
  );

  // Alternate rd value, merged with the JAL/JALR link value so the
  // ALU -> EX/MEM path keeps a single 2:1 mux. Selects and alt_val come
  // only from registers (ID/EX, div_unit), never from the ALU.
  logic        use_alt;
  logic [31:0] alt_val;
  always_comb begin
    use_alt = in.ctrl.is_jump || div_done;
    alt_val = div_done ? div_q : (in.pc + 32'd4);
  end

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
      BR_BEQ:  branch_cond = (rs1 == rs2);
      BR_BNE:  branch_cond = (rs1 != rs2);
      BR_BLT:  branch_cond = ($signed(rs1) <  $signed(rs2));
      BR_BGE:  branch_cond = ($signed(rs1) >= $signed(rs2));
      BR_BLTU: branch_cond = (rs1 <  rs2);
      BR_BGEU: branch_cond = (rs1 >= rs2);
      default: branch_cond = 1'b0;
    endcase
    branch_taken  = in.ctrl.is_branch && branch_cond;
    branch_target = in.pc + in.imm;
    // JALR clears bit 0 (RV spec); JAL uses imm directly.
    jalr_sum    = rs1 + in.imm;
    jump_target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0}
                                  : (in.pc + in.imm);
  end

  // ── Misaligned branch / jump target trap ──────────────────────────────
  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, suppress the redirect (PC stays linear), and clear
  // reg_write so JAL/JALR don't write the return address on trap.
  // The illegal-encoding decode proper is ORed in by MEM from
  // EX/MEM.instr; ID/EX.ctrl.is_illegal carries only ID's opcode check.
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
    if (misalign_fault)
      ctrl_with_trap.is_illegal = 1'b1;
    // Only a misaligned JAL/JALR has a reg_write to clear: branches never
    // write rd (decoder leaves reg_write=0), so the slow branch-compare ->
    // misalign_branch term stays off the reg_write / forwarding-enable
    // path. A busy divide also takes a bubble here (no regfile write, no
    // forward); it has no memory op, so mem_read/mem_write are already 0.
    // A late-killed instruction becomes a bubble: no write, no dmem op.
    if (misalign_jump || ex_div_busy || late_kill)
      ctrl_with_trap.reg_write  = 1'b0;
    if (late_kill) begin
      ctrl_with_trap.mem_read   = 1'b0;
      ctrl_with_trap.mem_write  = 1'b0;
    end
  end

  // ── Prediction check ──────────────────────────────────────────────────
  // actual_taken is the architectural control transfer (a misaligned
  // target traps and falls through). IF never predicts a misaligned
  // target or a JALR, and pred_target was formed from the same
  // instruction bits, so only the direction can be wrong: redirect =
  // mispredict, to the path IF did not take. A bubble or a divide
  // carries pred_taken = 0, so the EX term stays 0 while ex_div_busy is
  // high. late_kill (a flop) overrides: this stage's instruction is then
  // younger than the late branch, i.e. wrong-path.
  logic actual_taken;

  always_comb begin
    actual_taken    = (branch_taken || in.ctrl.is_jump) && !misalign_fault;
    redirect        = (actual_taken ^ in.pred_taken) || late_kill;
    redirect_target = late_kill       ? late_tgt
                    : in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0}
                    :                   in.alt_target;
  end

  // ── BHT update (registered, written into IF next cycle) ───────────────
  // Repeated writes while EX is held (dmem stall) are idempotent: the
  // held branch's operands and fetch-time counter do not change. A
  // late-killed branch registers no write. The core merges this port
  // with MEM's late-branch write, which wins a same-cycle collision.
  logic [1:0]           ctr_inc;
  logic [1:0]           ctr_dec;
  logic                 bht_we_q;
  logic [BHT_IDX_W-1:0] bht_widx_q;
  logic [1:0]           bht_wdata_q;

  always_comb begin
    ctr_inc = (in.bht_ctr == 2'b11) ? 2'b11 : in.bht_ctr + 2'd1;
    ctr_dec = (in.bht_ctr == 2'b00) ? 2'b00 : in.bht_ctr - 2'd1;
  end

  always_ff @(posedge clock) begin
    if (reset) bht_we_q <= 1'b0;
    else       bht_we_q <= in.valid && in.ctrl.is_branch && !late_kill;
    bht_widx_q  <= in.pc[BHT_IDX_W+1:2];
    bht_wdata_q <= branch_cond ? ctr_inc : ctr_dec;
  end

  assign bht_we    = bht_we_q;
  assign bht_widx  = bht_widx_q;
  assign bht_wdata = bht_wdata_q;

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
      // sum (which is the jump target); for a finished divide it is the
      // div_unit result. The MEM/WB register's read-data mux only kicks in
      // for LOADs, so both are routed here through alt_val.
      reg_q.alu_result    <= use_alt ? alt_val : alu_result;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      // A finished divide reports the operands latched at its launch.
      reg_q.rs1_val       <= div_done ? div_rs1_q : rs1;
      reg_q.rs2_val       <= div_done ? div_rs2_q : rs2;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect.
      reg_q.pc_next       <= misalign_fault     ? (in.pc + 32'd4)
                            : in.ctrl.is_jump   ? jump_target
                            : branch_taken      ? branch_target
                                                : (in.pc + 32'd4);
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      // Late branch: MEM resolves it. The LOAD it depends on is in EX/MEM
      // right now, so the forward unit's EX/MEM match (from flops) says
      // which operand is the LOAD's rd; MEM substitutes MEM/WB.read_data
      // there.
      reg_q.late          <= in.late && !late_kill;
      reg_q.late_rs1      <= in.late && (fwd_rs1_sel == 2'd1);
      reg_q.late_rs2      <= in.late && (fwd_rs2_sel == 2'd1);
      reg_q.late_pred     <= in.late_pred;
      reg_q.bht_ctr       <= in.bht_ctr;
      reg_q.valid         <= in.valid && !ex_div_busy && !late_kill;
    end
  end

  assign out = reg_q;

endmodule
