// rtl/ex_stage.sv
//
// Execute stage. Applies the only EX-side bypass (the instruction
// immediately ahead, from EX/MEM.alu_result), runs the ALU, resolves
// branches, computes the redirect target. Owns the EX/MEM pipeline
// register.
//
// ID/EX delivers rs1_val / rs2_val and the pre-selected ALU operands
// op_a / op_b already resolved against every older producer except the
// 1-ahead one (id_stage). Each operand here is one 2:1 mux on a select
// from forward_unit (registered hit AND live EX/MEM reg_write).
//
// Wrong-path kill: the word fetched behind a taken branch / jump enters
// ID/EX with squash = 1. Here it cannot redirect or start the divider,
// and it reaches EX/MEM as a bubble (valid / reg_write / mem_* cleared).
//
// MUL* / DIV* results go to EX/MEM.xres, selected in MEM (mem_stage), so
// the DSP and divider outputs never reach EX/MEM.alu_result and the EX
// 1-ahead bypass; hazard_unit interlocks a consumer directly behind.
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4 via the ALU ADD), and the
//                 branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  // in.*_hit* are consumed by forward_unit (fwd_*), not here.
  /* verilator lint_off UNUSEDSIGNAL */
  input  id_ex_t   in,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic               fwd_rs1,       // rs1     <- EX/MEM.alu_result
  input  logic               fwd_rs2,       // rs2     <- EX/MEM.alu_result
  input  logic               fwd_a,         // ALU a   <- EX/MEM.alu_result
  input  logic               fwd_b,         // ALU b   <- EX/MEM.alu_result
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  output ex_mem_t  out,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               div_busy       // DIV* in EX, result not ready
);

  // ── 1-ahead bypass ─────────────────────────────────────────────────────
  // rs1 / rs2 feed the AGU, branch comparator, JALR adder, divider, store
  // data and RVFI; alu_a / alu_b feed only the ALU.
  logic [31:0] rs1;
  logic [31:0] rs2;
  logic [31:0] alu_a;
  logic [31:0] alu_b;

  always_comb begin
    rs1   = fwd_rs1 ? fwd_ex_mem : in.rs1_val;
    rs2   = fwd_rs2 ? fwd_ex_mem : in.rs2_val;
    alu_a = fwd_a   ? fwd_ex_mem : in.op_a;
    alu_b = fwd_b   ? fwd_ex_mem : in.op_b;
  end

  logic [31:0] alu_mul_out;
  logic [31:0] alu_base;
  alu_core u_alu (
    .sel      (in.alu_sel),
    .a        (alu_a),
    .b        (alu_b),
    .base_out (alu_base),
    .mul_out  (alu_mul_out)
  );

  // ── Dedicated AGU ─────────────────────────────────────────────────────
  // LOAD/STORE address rs1 + imm on its own adder, so the dmem address
  // register (absorbed into the BSRAM) sees no ALU result logic.
  logic [31:0] mem_addr;
  assign mem_addr = rs1 + in.imm;

  // ── Sequential divider (DIV / DIVU / REM / REMU) ──────────────────────
  // The divide sits in ID/EX while the divider runs (div_busy freezes
  // IF/ID via the hazard unit) and EX/MEM captures bubbles. Operands are
  // latched at start; the older producers drain meanwhile, so at
  // completion rs?_val for RVFI come from the divider's latched copies.
  // in.is_div is cleared on bubbles; a squashed DIV* never starts.
  logic        is_div;
  logic        div_idle;
  logic        div_done;
  logic [31:0] div_result;
  logic [31:0] div_a;
  logic [31:0] div_b;

  always_comb begin
    is_div   = in.is_div && !in.squash;
    div_busy = is_div && !div_done;
  end

  divider u_div (
    .clock     (clock),
    .reset     (reset),
    .start     (is_div && div_idle && !stall),
    .is_rem    (in.div_rem),
    .is_signed (in.div_signed),
    .a         (rs1),
    .b         (rs2),
    .advance   (!stall),
    .idle      (div_idle),
    .done      (div_done),
    .result    (div_result),
    .a_latched (div_a),
    .b_latched (div_b)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  // One-hot compare selects registered in ID: cond is 1-2 LUTs after the
  // comparator chains. The branch / JAL target pc + imm was added in ID
  // (in.pc_imm); only JALR adds here. pc is 4-aligned, so a branch / JAL
  // target is misaligned iff imm[1] (registered as br_ok / jal_ok /
  // jal_mis); only JALR looks at the bypassed rs1's low bits.
  logic        eq, lt, ltu;
  logic        branch_cond;
  logic        jalr_ok;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] jalr_sum;  // bit 0 deliberately dropped per RV JALR spec
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    eq  = (rs1 == rs2);
    lt  = ($signed(rs1) < $signed(rs2));
    ltu = (rs1 < rs2);
    branch_cond = in.cmp_inv ^ ((in.sel_eq  && eq) ||
                                (in.sel_lt  && lt) ||
                                (in.sel_ltu && ltu));
    jalr_sum = rs1 + in.imm;
    jalr_ok  = in.ctrl.is_jalr && !jalr_sum[1];
  end

  assign redirect        = !in.squash &&
                           (in.jal_ok || jalr_ok || (in.br_ok && branch_cond));
  assign redirect_target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0} : in.pc_imm;

  // ── Misaligned branch / jump target trap ──────────────────────────────
  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, suppress the redirect (PC stays linear), and clear
  // reg_write so JAL/JALR don't write the return address on trap. A
  // branch never writes rd, so its compare stays off reg_write.
  logic  misalign_branch;
  logic  misalign_jump;
  logic  misalign_fault;
  logic  branch_taken;
  logic [31:0] pc_plus4;
  logic [31:0] pc_tgt;
  logic [31:0] jump_target;
  ctrl_t ctrl_next;

  // RVFI-only: a steered branch (pred) has cmp_inv inverted and pc_imm =
  // pc + 4, so the real outcome is branch_cond ^ pred and the real B/J
  // target is recomputed here (pruned by synthesis).
  always_comb begin
    branch_taken    = in.ctrl.is_branch && (branch_cond ^ in.pred);
    misalign_branch = branch_taken && in.imm[1];
    misalign_jump   = in.jal_mis || (in.ctrl.is_jalr && jalr_sum[1]);
    misalign_fault  = misalign_branch || misalign_jump;
    pc_plus4        = in.pc + 32'd4;
    pc_tgt          = in.pc + in.imm;
    jump_target     = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0} : pc_tgt;

    ctrl_next = in.ctrl;
    if (misalign_fault) ctrl_next.is_illegal = 1'b1;
    // Squashed wrong-path word, a trapping jump, or a divide still
    // running: EX/MEM takes a bubble (valid cleared below). Forwarding
    // looks at reg_write and the dmem ports at mem_read / mem_write.
    ctrl_next.reg_write = in.ctrl.reg_write && !in.squash && !misalign_jump
                          && !div_busy;
    ctrl_next.mem_read  = in.ctrl.mem_read  && !in.squash;
    ctrl_next.mem_write = in.ctrl.mem_write && !in.squash;
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
      // For JAL/JALR the ALU itself computes the return address PC+4
      // (ID pre-selects a = pc, b = 4, ADD).
      reg_q.alu_result    <= alu_base;
      // div_done implies the DIV* itself is in EX.
      reg_q.xres          <= div_done ? div_result : alu_mul_out;
      reg_q.res_late      <= in.res_late;
      reg_q.mem_addr      <= mem_addr;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= div_done ? div_a : rs1;
      reg_q.rs2_val       <= div_done ? div_b : rs2;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect. RVFI-only.
      reg_q.pc_next       <= misalign_fault     ? pc_plus4
                            : in.ctrl.is_jump   ? jump_target
                            : branch_taken      ? pc_tgt
                                                : pc_plus4;
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= pc_tgt;
      reg_q.ctrl          <= ctrl_next;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid && !in.squash && !div_busy;
    end
  end

  assign out = reg_q;

endmodule
