// rtl/ex_stage.sv
//
// Execute stage. Runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// The operands arrive final: id_stage resolves forwarding, the AUIPC pc and
// the ALU immediate at the end of ID, so in.op1 / in.op2 launch straight
// from ID/EX flops into the ALU, the branch compare, the rs1+imm adder, the
// divider and the store-data path. There is no forward mux, no select flop
// and no alu_a/alu_b mux in EX. The pure forwarded register values for RVFI
// rs?_rdata travel separately as in.rv1 / in.rv2.
//
// EX also exports `fwd_val` (this cycle's result, the ex-now forwarding term
// of the instruction in ID). Late producers (loads, JAL/JALR, MUL*) are never
// forwarded from here; their consumer waits one cycle (hazard_unit).
//
// DIV/DIVU/REM/REMU run in the sequential divider (divider.sv, ~36
// cycles). While it runs the divide stays in EX: `ex_busy` tells the
// hazard unit to hold IF and ID/EX, and EX/MEM captures bubbles so
// nothing younger advances. When the divider reaches DONE the result
// replaces the ALU result and the divide advances normally. Under
// RISCV_FORMAL_ALTOPS the divider is compiled out and the ALU's XOR
// stand-ins are used (ex_busy = 0).
//
// The redirect is a REGISTERED event. The branch compare (the deepest EX
// path) ends at the single D pin of `redir_q`; `redirect` / `redirect_target`
// are the flop outputs, so the compare no longer fans out into the PC mux,
// the IF/ID valid masks and the ID/EX flush in the same cycle. The cost is
// one extra bubble per redirect. Cycle t: mispredicted X in EX, wrong-path A
// captured into ID/EX, redir_q <= 1. Cycle t+1: X in MEM, A in EX, B fetched;
// redir_q = 1 flushes B / sets pc <= redir_tgt_q (IF, hazard unit) and A is
// squashed HERE: EX/MEM takes a bubble (`ex_busy || redir_q`; mul_q needs no
// clear, a bubble's reg_write = 0 keeps its product from any consumer), A may
// not redirect (redirect_raw is gated by !redir_q) and may not start the
// divider (is_div_op is gated by !redir_q). No dmem stall can coincide with
// redir_q: the only instruction in MEM at t+1 is X itself (a non-memory op),
// and redirect_raw is gated by `stall`, so X really did leave EX at t.
//
// Latency:        1 cycle (EX/MEM register clocked here); divides take
//                 ~36 cycles in EX; a redirect takes effect one cycle after
//                 the branch resolves.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  output ex_mem_t  out,
  output logic [31:0]        fwd_val,       // EX result now (ex-now term of ID's operand forward)
  output logic               ex_busy,       // divide in EX not yet finished
  output logic               redirect,      // registered: a branch/jump resolved last cycle
  output logic [31:0]        redirect_target
);

  // ── Operands (final, straight from the ID/EX flops) ───────────────────
  ex_mem_t     reg_q;
  logic [31:0] mul_q;   // DSP-product half of EX/MEM.alu_result (0 for non-MUL;
                        // not cleared by bubbles: reg_write = 0 gates its readers)
  logic        redir_q;       // registered redirect (1 for the cycle after resolve)
  logic [31:0] redir_tgt_q;   // its target (only consumed while redir_q = 1)

  logic [31:0] rs1;
  logic [31:0] rs2;
  assign rs1 = in.op1;
  assign rs2 = in.op2;

  // The ALU's own `out` (full result) is only used by test_alu.py; here the
  // fast legs and the late multiplier product are muxed separately below.
  logic [31:0] alu_fast;
  logic [31:0] alu_mul_lo;
  logic [31:0] alu_mul_hi;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] alu_out_unused;
  /* verilator lint_on UNUSEDSIGNAL */
`ifdef RISCV_FORMAL_ALTOPS
  // ALTOPS: the ALU decodes alu_op itself (the stand-ins cover every M op).
  localparam bit PREDEC = 1'b0;
`else
  // The DSP signedness, lo/hi merge and ALU result class are registered
  // one-hot flags in ID/EX ctrl (decoded in ID): no alu_op decode in EX.
  localparam bit PREDEC = 1'b1;
`endif
  alu #(.HW_DIV(1'b0), .PREDEC(PREDEC)) u_alu (
    .op         (in.ctrl.alu_op),
    .msa_i      (in.ctrl.mul_sa),
    .msb_i      (in.ctrl.mul_sb),
    .sel_mul_lo (in.ctrl.sel_mul_lo),
    .sel_mul_hi (in.ctrl.sel_mul_hi),
    .sel_add    (in.ctrl.sel_add),
    .sel_sub    (in.ctrl.sel_sub),
    .sel_and    (in.ctrl.sel_and),
    .sel_or     (in.ctrl.sel_or),
    .sel_xor    (in.ctrl.sel_xor),
    .sel_slt    (in.ctrl.sel_slt),
    .sel_sltu   (in.ctrl.sel_sltu),
    .sel_sll    (in.ctrl.sel_sll),
    .sel_srl    (in.ctrl.sel_srl),
    .sel_sra    (in.ctrl.sel_sra),
    .sel_lui    (in.ctrl.sel_lui),
    .a          (rs1),
    .b          (rs2),
    .out        (alu_out_unused),
    .fast_out   (alu_fast),
    .mul_lo     (alu_mul_lo),
    .mul_hi     (alu_mul_hi)
  );

  // ── Sequential divider ────────────────────────────────────────────────
  logic        is_div_op;
  logic [31:0] div_result;
  logic [31:0] div_op_a;   // latched rs1 / rs2 of the divide (RVFI only)
  logic [31:0] div_op_b;

`ifndef RISCV_FORMAL_ALTOPS
  logic        div_done;
  always_comb begin
    // A wrong-path divide squashed by redir_q must not start the divider
    // (it would raise ex_busy and suppress the redirect's flush_id).
    is_div_op = in.valid && !redir_q && in.ctrl.is_div;
    ex_busy   = is_div_op && !div_done;
  end

  divider u_div (
    .clock     (clock),
    .reset     (reset),
    .start     (is_div_op),
    .a         (rs1),
    .b         (rs2),
    .is_signed (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_REM),
    .want_rem  (in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU),
    .advance   (div_done && !stall),
    .done      (div_done),
    .result    (div_result),
    .op_a      (div_op_a),
    .op_b      (div_op_b)
  );
`else
  // Formal (ALTOPS): divide is the ALU's XOR stand-in, combinational.
  always_comb begin
    is_div_op  = 1'b0;
    ex_busy    = 1'b0;
    div_result = 32'b0;
    div_op_a   = 32'b0;
    div_op_b   = 32'b0;
  end
`endif

  // Result that bypasses the ALU in the EX/MEM alu_result slot: PC+4 for
  // JAL/JALR, the divider's result for a finished divide. These and the
  // fast ALU legs (adder/logic/shift) are merged into `early_masked`.
  // The DSP product arrives several ns after them, so it gets its own
  // EX/MEM flop set (`mul_q`, selected lo/hi by the registered sel_mul_lo/hi
  // flags in a single LUT after the DSP) and is merged with the early flops
  // by a one-LUT OR on the EX/MEM output. That OR sits on the EX/MEM
  // forwarding leg, which launches from a flop well ahead of the regfile
  // BSRAM leg, so it is hidden; the DSP -> flop leg is 1 LUT.
  logic [31:0] early_masked;
  logic [31:0] mul_result;
  always_comb begin
`ifdef RISCV_FORMAL_ALTOPS
    // ALTOPS: the multiplier ops are the ALU's XOR stand-ins (fast leg); the
    // ALU decodes alu_op itself, so JAL/JALR still need the explicit mux.
    early_masked = in.ctrl.is_jump ? (in.pc + 32'd4) : alu_fast;
    mul_result   = 32'b0;
`else
    // alu_fast is 0 for JAL/JALR, MUL* and DIV* (no result class is set for
    // them), so the pc+4 / divider / ALU legs merge in one flat AND-OR.
    early_masked = alu_fast
                 | ({32{in.ctrl.is_jump}} & (in.pc + 32'd4))
                 | ({32{is_div_op}}       & div_result);
    mul_result   = ({32{in.ctrl.sel_mul_lo}} & alu_mul_lo)
                 | ({32{in.ctrl.sel_mul_hi}} & alu_mul_hi);
`endif
  end

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] jump_target;
  logic [31:0] jalr_sum;  // rs1 + imm: JALR target (bit 0 cleared) / dmem address

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

  // ── Misaligned branch / jump / load / store trap ──────────────────────
  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, suppress the redirect (PC stays linear), and clear
  // reg_write so JAL/JALR don't write the return address on trap.
  //
  // Loads/stores are decided here too (RV32I: word-aligned LW/SW,
  // halfword-aligned LH/LHU/SH, bytes always aligned; the effective address
  // is jalr_sum, the dedicated rs1+imm adder). The trap clears reg_write and
  // sets is_illegal on the way into EX/MEM, and the registered `mem_mis` flag
  // gates the dmem ports and RVFI masks in MEM, so mem_stage needs no
  // address-based misalign decode and the MEM-stage reg_write is a flop.
  logic misalign_branch;
  logic misalign_jump;
  logic misalign_mem;
  logic misalign_fault;
  ctrl_t ctrl_with_trap;

  always_comb begin
    misalign_branch = in.ctrl.is_branch && branch_taken
                      && (branch_target[1:0] != 2'b00);
    misalign_jump   = in.ctrl.is_jump && (jump_target[1:0] != 2'b00);
    misalign_fault  = misalign_branch || misalign_jump;
    misalign_mem    = (in.ctrl.mem_read || in.ctrl.mem_write) && (
                        (in.ctrl.mem_width == 2'd2 && jalr_sum[1:0] != 2'b00) ||
                        (in.ctrl.mem_width == 2'd1 && jalr_sum[0]   != 1'b0));
                        // 2'd0 (byte) is never misaligned.

    ctrl_with_trap = in.ctrl;
    if (misalign_fault || misalign_mem) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
    ctrl_with_trap.mem_mis = misalign_mem;
  end

  // Fetch already followed the prediction (in.pred_taken), so redirect only
  // when the actual outcome differs from it. JALR is never predicted, so it
  // always redirects. A misaligned target suppresses the redirect (the PC
  // stays linear); IF never predicts a misaligned target.
  //
  // redirect_raw is the late (end-of-compare) 1-bit event; it only feeds the
  // D pin of redir_q. It is gated by !stall (the branch has not left EX yet;
  // it retries when it advances) and by !redir_q (the instruction in EX during
  // the redirect cycle is wrong-path and is squashed, so it cannot redirect).
  logic actual_taken;
  logic redirect_raw;
  logic [31:0] redirect_target_d;
  assign actual_taken    = branch_taken || in.ctrl.is_jump;
  assign redirect_raw    = (actual_taken ^ in.pred_taken) && !misalign_fault
                           && !redir_q && !stall;
  // redirect with pred_taken => predicted taken, actually not taken -> pc+4.
  // redirect without it       => actually taken, predicted not    -> target.
  // Keying on the registered pred_taken keeps the late branch compare off
  // the redirect target data path.
  assign redirect_target_d = in.pred_taken  ? (in.pc + 32'd4)
                           : in.ctrl.is_jump ? jump_target
                                             : branch_target;

  always_ff @(posedge clock) begin
    if (reset) redir_q <= 1'b0;
    else       redir_q <= redirect_raw;
  end

  // No reset / CE: only consumed while redir_q = 1, which implies it was
  // loaded the cycle before.
  always_ff @(posedge clock) begin
    redir_tgt_q <= redirect_target_d;
  end

  assign redirect        = redir_q;
  assign redirect_target = redir_tgt_q;

  // ── EX/MEM register ───────────────────────────────────────────────────
  always_ff @(posedge clock) begin
    if (reset) begin
      mul_q <= '0;
    end else if (!stall) begin
      mul_q <= mul_result;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (ex_busy || redir_q) begin
      // Divide still running in EX: inject a bubble so nothing younger
      // advances and the zeroed ctrl (reg_write = 0) disables forwarding
      // from it. redir_q: the instruction in EX is the wrong-path one behind
      // the resolved branch -- squash it (it never retires, writes a
      // register, touches dmem, trains the BHT or forwards).
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here. A finished
      // divide routes the divider's result instead.
      reg_q.alu_result    <= early_masked;
      // Load/store address: the dedicated rs1 + imm adder, no ALU result
      // mux behind it (a LOAD/STORE's ALU op is ADD of exactly these).
      reg_q.mem_addr      <= jalr_sum;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      // RVFI-only: a divide's live forwarding muxes are stale by the time
      // it finishes, so report the operands the divider latched.
      reg_q.rs1_val       <= is_div_op ? div_op_a : in.rv1;
      reg_q.rs2_val       <= is_div_op ? div_op_b : in.rv2;
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
      reg_q.valid         <= in.valid;
    end
  end

  assign fwd_val = early_masked;

  // EX/MEM.alu_result = early flops | DSP-product flops (one of the two is 0).
  always_comb begin
    out            = reg_q;
    out.alu_result = reg_q.alu_result | mul_q;
  end

endmodule
