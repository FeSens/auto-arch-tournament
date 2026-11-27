// rtl/ex_stage.sv
//
// Execute stage. Runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// There is NO operand forwarding and NO operand selection here:
//   - ID/EX.rs1_val / rs2_val are the final architectural register
//     values (the bypass network sits in front of the ID/EX register,
//     see id_stage). They feed the branch compare, the JALR target, the
//     AGU, the store data, the multiplier and the divider.
//   - ID/EX.op_a / op_b are the final ALU operands (pc / rs1 and
//     4 / imm / rs2, chosen in ID). They feed the ALU's non-M arms.
// EX exports its result (`ex_result` = the ALU output = the value
// written to EX/MEM.alu_result this cycle; for JAL/JALR that is the
// link address pc + 4, computed by the ALU adder) and the matching
// enable (`ex_byp_en`) as the EX leg of the bypass network.
//
// AGU: the data-memory address rs1 + imm has its own adder and its own
// EX/MEM register (mem_addr). No ALU result ever reaches the dmem
// address pins; the same sum is the JALR target.
//
// DIV/DIVU/REM/REMU are multi-cycle: a shared sequential divider
// (div_unit) sits beside the ALU. While it runs, `ex_busy` holds the
// PC and ID/EX (hazard_unit) and EX/MEM is fed bubbles.
//
// Latency:        1 cycle (EX/MEM register clocked here); DIV/REM stay
//                 in EX until the divider is done.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), mem_addr (AGU) and the branch
//                 resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  output ex_mem_t  out,
  output logic               ex_busy,       // DIV/REM in EX still computing
  // EX leg of the ID-stage bypass network.
  output logic               ex_byp_en,     // EX instr writes in.rd (non-x0, not trapping)
  output logic [31:0]        ex_result,     // next EX/MEM.alu_result
  output logic               redirect,
  output logic [31:0]        redirect_target
);

  // ── Operands: straight from the ID/EX flops ───────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;
  assign rs1 = in.rs1_val;
  assign rs2 = in.rs2_val;

  // ── AGU: data-memory address (and JALR target) ────────────────────────
  // Flops -> one carry chain -> EX/MEM.mem_addr. Not part of the ALU.
  logic [31:0] agu_addr;
  assign agu_addr = rs1 + in.imm;

  // ── Sequential divider (DIV/DIVU/REM/REMU) ────────────────────────────
  // is_div / ex_busy are functions of registers only (ID/EX alu_op and
  // valid, divider FSM state) — never of operand values.
  //
  // The divide starts on the first cycle the DIV/REM sits in EX. The
  // instruction then waits in ID/EX (hazard_unit holds PC and ID/EX on
  // ex_busy) while EX/MEM is fed bubbles; once `div_done` is up it moves
  // on like any other instruction, with the registered divider result
  // selected by the ALU mux. `div_done` is sticky until the DIV really
  // leaves EX, so a dmem stall on the done cycle is harmless.
  logic        is_div;
  logic        div_start;
  logic        div_clear;
  logic        div_done;
  /* verilator lint_off UNUSEDSIGNAL */
  logic        div_running;   // exported by div_unit for unit tests
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] div_result;

  always_comb begin
    is_div    = in.valid && (in.ctrl.alu_op == ALU_DIV  ||
                             in.ctrl.alu_op == ALU_DIVU ||
                             in.ctrl.alu_op == ALU_REM  ||
                             in.ctrl.alu_op == ALU_REMU);
    ex_busy   = is_div && !div_done;
    div_start = is_div && !div_done && !div_running;
    div_clear = is_div && div_done && !stall;
  end

  div_unit u_div (
    .clock     (clock),
    .reset     (reset),
    .start     (div_start),
    .clear     (div_clear),
    .op_signed (in.ctrl.alu_op == ALU_DIV  || in.ctrl.alu_op == ALU_REM),
    .op_rem    (in.ctrl.alu_op == ALU_REM  || in.ctrl.alu_op == ALU_REMU),
    .a         (rs1),
    .b         (rs2),
    .busy      (div_running),
    .done      (div_done),
    .result    (div_result)
  );

  logic [31:0] alu_result;
  alu u_alu (
    .op         (in.ctrl.alu_op),
    .a          (in.op_a),
    .b          (in.op_b),
    .ma         (rs1),
    .mb         (rs2),
    .div_result (div_result),
    .out        (alu_result)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] jump_target;

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
    // JALR target = rs1 + imm (the AGU sum) with bit 0 cleared (RV
    // spec); JAL and BRANCH use pc + imm. is_jalr implies is_jump, so
    // this single registered-select 2:1 mux is the whole target mux.
    jump_target = in.ctrl.is_jalr ? {agu_addr[31:1], 1'b0}
                                  : branch_target;
  end

  // ── Misaligned branch / jump target trap ──────────────────────────────
  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, suppress the redirect (PC stays linear), and clear
  // reg_write so JAL/JALR don't write the return address on trap.
  //
  // The low two target bits are computed with dedicated 2-bit adders so
  // the trap decision (which gates the EX bypass enable and redirect)
  // does not wait for the 32-bit target adders.
  logic [1:0] pcrel_lo;       // (pc + imm)[1:0]   — branch and JAL target
  /* verilator lint_off UNUSEDSIGNAL */
  logic [1:0] jalr_lo;        // (rs1 + imm)[1:0]  — JALR target, bit 0 dropped
  /* verilator lint_on UNUSEDSIGNAL */
  logic pcrel_ok;             // pc-relative target is 4-byte aligned
  logic jump_ok;              // is_jump and its target is aligned
  logic misalign_branch;
  logic misalign_jump;
  logic misalign_fault;
  ctrl_t ctrl_with_trap;

  always_comb begin
    pcrel_lo = in.pc[1:0] + in.imm[1:0];
    jalr_lo  = rs1[1:0]   + in.imm[1:0];
    pcrel_ok = (pcrel_lo == 2'b00);
    jump_ok  = in.ctrl.is_jump
               && (in.ctrl.is_jalr ? !jalr_lo[1] : pcrel_ok);

    misalign_branch = branch_taken && !pcrel_ok;
    misalign_jump   = in.ctrl.is_jump && !jump_ok;
    misalign_fault  = misalign_branch || misalign_jump;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  // Redirect = same-cycle fetch-address override (if_stage). Both
  // outputs are functions of the ID/EX flops only. is_branch and is_jump
  // are mutually exclusive, so the misalign suppression folds into the
  // two product terms: only the compare itself is late.
  assign redirect        = (branch_taken && pcrel_ok) || jump_ok;
  assign redirect_target = jump_target;

  // ── EX result / bypass leg ────────────────────────────────────────────
  // The ALU output IS the EX result: for JAL/JALR the operands captured
  // in ID are (pc, 4) with alu_op = ADD, so the link address needs no
  // mux behind the ALU. A bubble has ctrl = 0, so reg_write alone
  // implies a real instruction. A trapping JAL/JALR does not write and must not bypass
  // (branches never write, so only misalign_jump matters). A LOAD in EX
  // may raise ex_byp_en, but its consumer is held in ID by the load-use
  // bubble and never captures this leg.
  assign ex_result = alu_result;
  assign ex_byp_en = in.ctrl.reg_write && (in.rd != 5'b0) && !misalign_jump;

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
      reg_q.alu_result    <= ex_result;
      reg_q.mem_addr      <= agu_addr;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= rs1;
      reg_q.rs2_val       <= rs2;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect.
      reg_q.pc_next       <= redirect ? redirect_target : (in.pc + 32'd4);
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
      // Divide in progress: EX/MEM captures a bubble so MEM and WB drain
      // and retire normally while the DIV/REM waits in ID/EX. Every
      // field that can have an effect downstream is cleared (valid, the
      // whole ctrl bundle -> no reg write, no bypass match, no dmem
      // access, no retirement; rd for good measure). The wide data
      // fields are don't-care in a bubble and are deliberately NOT
      // gated: alu -> EX/MEM.alu_result and AGU -> EX/MEM.mem_addr
      // (-> dmem address) must not grow an extra AND level.
      if (ex_busy) begin
        reg_q.ctrl        <= '0;
        reg_q.rd          <= 5'b0;
        reg_q.valid       <= 1'b0;
      end
    end
  end

  assign out = reg_q;

endmodule
