// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// ID selects the youngest writing source on each forwarding port.
//
// Latency:        8 cycles for DIV/DIVU/REM/REMU, 1 cycle otherwise.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  logic               annul,
  input  logic               word_handoff,
  input  logic               predict_local,
  input  logic [31:0]        buffered_word,
  input  logic [31:0]        bus_word,
  input  logic [7:0]         resident_page,
  output logic [9:0]         read_index,
  output logic               lookup_page_match,
  input  id_ex_t   in,
  input  logic [2:0]         fwd_rs1_sel,
  input  logic [2:0]         fwd_rs2_sel,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // Selected result in MEM/WB
  input  logic [31:2]        wb_alu_word,
  input  logic [31:2]        wb_mem_word,
  input  logic               wb_mem_to_reg,
  output ex_mem_t  out,
  output logic               producer_writes,
  output logic               aligned_lw,
  output logic               defer_add,
  output logic               defer_branch,
  output logic [31:0]        rs1,
  output logic [31:0]        rs2,
  output logic               late_rs1,
  output logic               late_rs2,
  output logic               div_wait,
  output logic [31:2]        target_word,
  output logic               recover_target,
  output logic               recover_fallthrough
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  ex_mem_t reg_q;
  logic late_binary;
  assign late_rs1 = fwd_rs1_sel[0] && reg_q.ctrl.mem_to_reg;
  assign late_rs2 = fwd_rs2_sel[0] && reg_q.ctrl.mem_to_reg;
  assign late_binary = late_rs1 || late_rs2;
  assign defer_add = in.is_add && (late_rs1 || (!in.ctrl.alu_src && late_rs2));
  assign defer_branch = in.ctrl.is_branch && !in.ctrl.branch_op[2] && late_binary;

  assign rs1 = ({32{fwd_rs1_sel[0]}} & fwd_ex_mem) |
               ({32{fwd_rs1_sel[1]}} & fwd_mem_wb) |
               ({32{fwd_rs1_sel[2]}} & in.rs1_val);
  assign rs2 = ({32{fwd_rs2_sel[0]}} & fwd_ex_mem) |
               ({32{fwd_rs2_sel[1]}} & fwd_mem_wb) |
               ({32{fwd_rs2_sel[2]}} & in.rs2_val);

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    alu_a = in.ctrl.is_auipc ? in.pc  : rs1;
    alu_b = in.ctrl.alu_src  ? in.alu_imm : rs2;
  end

  logic [31:0] alu_result;
  logic is_div, div_busy, div_done;
  assign is_div = in.valid && !annul && in.is_div;
  assign div_wait = is_div && !div_done;

  alu #(.ENABLE_MUL(1'b0)) u_alu (
    .clock       (clock),
    .reset       (reset),
    .div_request (is_div && !stall),
    .div_busy    (div_busy),
    .div_done    (div_done),
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] target;
  assign target_word = target[31:2];
  // Race the three full addresses against the source decision. Only the
  // narrow RAM index assumes that a handed-off pointer is resident.
  logic [31:0] forwarded_addr, buffered_addr, bus_addr, mem_addr;
  logic [11:0] index_base;
  assign forwarded_addr = rs1 + in.imm;
  assign buffered_addr = buffered_word + in.imm;
  assign bus_addr = bus_word + in.imm;
  assign mem_addr = word_handoff ? (predict_local ? buffered_addr : bus_addr)
                                 : forwarded_addr;
  assign index_base = word_handoff ? buffered_word[11:0] : rs1[11:0];
  assign read_index = 10'((index_base + in.imm[11:0]) >> 2);
  // A signed 12-bit displacement can cross at most one page. Register
  // the high-bit comparisons alongside the index carry, so MEM needs
  // only a mux to validate the page indicated by the speculative base.
  wire [19:0] base_page = word_handoff ? buffered_word[31:12] : rs1[31:12];
  wire [19:0] page = {12'b0, resident_page};
  wire same_page = base_page == page;
  wire below_page = base_page == page - 20'd1;
  wire above_page = base_page == page + 20'd1;
  logic match_carry_q, match_no_carry_q, index_carry_q;
  always_ff @(posedge clock) begin
    if (!stall) begin
      match_carry_q <= in.imm[11] ? same_page : below_page;
      match_no_carry_q <= in.imm[11] ? above_page : same_page;
      index_carry_q <= index_base > ~in.imm[11:0];
    end
  end
  assign lookup_page_match = index_carry_q ? match_carry_q : match_no_carry_q;

  logic equal_hi, equal_lo, less_hi, less_lo, less;
  // Compare halves in parallel. If the signs differ, funct3[1] selects
  // whether the operand with bit 31 set is the smaller or larger one.
  assign equal_hi = rs1[31:16] == rs2[31:16];
  assign equal_lo = rs1[15:0] == rs2[15:0];
  assign less_hi  = rs1[31] != rs2[31] ? rs1[31] ^ in.ctrl.branch_op[1] :
                                         rs1[30:16] < rs2[30:16];
  assign less_lo  = rs1[15:0] < rs2[15:0];
  assign less     = less_hi || (equal_hi && less_lo);

  always_comb begin
    branch_cond   = (in.ctrl.branch_op[2] ? less : equal_hi && equal_lo) ^ in.ctrl.branch_op[0];
    branch_taken  = in.ctrl.is_branch && !defer_branch && branch_cond;
    branch_target = in.pc + in.imm;
    // JALR clears bit 0 (RV spec); JAL uses imm directly.
    target = in.ctrl.is_jalr ? {forwarded_addr[31:1], 1'b0} : branch_target;
  end

  // ── Misaligned branch / jump target trap ──────────────────────────────
  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, suppress the redirect (PC stays linear), and clear
  // reg_write so JAL/JALR don't write the return address on trap.
  logic transfer;
  logic misalign_fault;
  ctrl_t ctrl_with_trap;

  assign transfer = branch_taken || in.ctrl.is_jump;
  assign misalign_fault = transfer && target[1:0] != 2'b00;

  always_comb begin
    ctrl_with_trap = in.ctrl;
    ctrl_with_trap.mem_to_reg = in.ctrl.mem_to_reg || defer_add;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end
  // Suppress a trapping load before the ID forwarding comparisons latch.
  // An older matching writer in WB can then supply the preserved register.
  logic load_misaligned;
  assign load_misaligned = in.ctrl.mem_read &&
                          ((in.ctrl.mem_width == 2 && mem_addr[1:0] != 0) ||
                           (in.ctrl.mem_width == 1 && mem_addr[0]));
  assign producer_writes = !annul && ctrl_with_trap.reg_write && !load_misaligned;
  assign aligned_lw = !annul && in.ctrl.mem_read && in.ctrl.mem_width == 2 &&
                      mem_addr[1:0] == 0;

  // The tag and identical instruction fix the target of a direct transfer.
  // For JALR with no offset, compare all producers while bypass selects
  // settle. JALR clears bit 0 and the trap logic checks bit 1.
  logic [31:2] saved_word_addr;
  logic wb_match, base_match;
  assign saved_word_addr = {12'b0, in.prediction.target};
  assign wb_match = wb_mem_to_reg ? wb_mem_word == saved_word_addr :
                                    wb_alu_word == saved_word_addr;
  assign base_match = (fwd_rs1_sel[0] && fwd_ex_mem[31:2] == saved_word_addr) ||
                      (fwd_rs1_sel[1] && wb_match) ||
                      (fwd_rs1_sel[2] && in.rs1_val[31:2] == saved_word_addr);

  logic predicted_taken, target_match, taken;
  assign predicted_taken = in.prediction.hit && in.prediction.counter[1];
  assign taken = transfer && target[1:0] == 2'b00;
  assign target_match = in.ctrl.is_jalr ? in.imm == 0 && base_match : in.prediction.same_word;
  // The branch comparison can arrive late from either forwarding port.
  // Qualify each possible correction in parallel with that comparison.
  logic branch_needs_target, jump_needs_target, jump_aligned;
  assign branch_needs_target = in.ctrl.is_branch && !in.imm[1]
                            && (!predicted_taken || !in.prediction.same_word);
  assign jump_aligned = in.ctrl.is_jalr ? !forwarded_addr[1] : !in.imm[1];
  assign jump_needs_target = in.ctrl.is_jump && jump_aligned
                          && (!predicted_taken || !target_match);
  assign recover_target = !annul && (jump_needs_target || (branch_needs_target && branch_taken));
  assign recover_fallthrough = !annul && !defer_branch && in.valid && predicted_taken && !(in.ctrl.is_jump && jump_aligned)
                            && !(in.ctrl.is_branch && !in.imm[1] && branch_cond);

  // ── EX/MEM register ───────────────────────────────────────────────────
  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else begin
      reg_q.pc            <= in.pc;
      reg_q.alu_result    <= alu_result;
      reg_q.mem_addr      <= mem_addr;
      // Capture the operands while the forwarding sources are still live.
      // These EX/MEM fields can hold them across the invalid divider slots.
      if (!div_busy) begin
        reg_q.write_data <= rs2;
        reg_q.rs1_val    <= rs1;
        reg_q.rs2_val    <= rs2;
      end
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      // MEM chooses fallthrough for a trapping transfer and supplies the
      // actual branch outcome if equality needs a WB operand.
      reg_q.early_taken   <= taken;
      reg_q.eligible_jump <= in.ctrl.is_jump && (!in.ctrl.is_jalr || in.imm == 0);
      reg_q.late_rs1      <= late_rs1;
      reg_q.late_rs2      <= late_rs2;
      reg_q.both_late     <= late_rs1 && late_rs2 && !in.ctrl.alu_src;
      reg_q.other_operand <= in.ctrl.alu_src ? in.imm : late_rs1 ? rs2 : rs1;
      reg_q.mul_lhs_negative <= (in.ctrl.alu_op == ALU_MULH || in.ctrl.alu_op == ALU_MULHSU) && rs1[31];
      reg_q.mul_rhs_negative <= in.ctrl.alu_op == ALU_MULH && rs2[31];
      reg_q.deferred_add  <= defer_add;
      reg_q.deferred_branch <= defer_branch && !annul;
      reg_q.predicted_taken <= predicted_taken;
      reg_q.prediction_matches <= in.prediction.hit && in.prediction.same_word;
      reg_q.old_counter   <= in.prediction.counter;
      reg_q.branch_target <= target;
      reg_q.ctrl          <= (div_wait || annul) ? '0 : ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid && !div_wait && !annul;
    end
  end

  assign out = reg_q;

endmodule
