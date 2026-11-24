// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// Decode registers mutually exclusive EX/MEM and MEM/WB bypass selects.
//
// Latency:        1 cycle for integer/multiply, variable for divide/remainder.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  input  logic               is_mul,        // valid MUL-family entry in ID/EX
  input  logic [31:0]        fallthrough_pc,
  output logic [31:0]        mem_product,
  output logic               is_div,
  output logic [31:0]        div_result,
  input  logic [31:0]        early_word,
  output logic [31:0]        mem_addr,
  input  logic [2:0]         fwd_rs1_sel,
  input  logic [2:0]         fwd_rs2_sel,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // MEM/WB.write_data
  input  logic               forecast_used,
  input  logic [31:0]        forecast_pc,
  output ex_mem_t  out,
  output logic               writes_rd,     // write control entering EX/MEM on advance
  output logic               div_wait,
  output logic               redirect,
  output logic               train_en,
  output logic [5:0]         train_index,
  output logic [1:0]         train_value
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  // Decode clears the register-file contribution when a bypass wins.
  assign rs1 = in.rs1_val | ({32{fwd_rs1_sel[0]}} & fwd_ex_mem)
                          | ({32{fwd_rs1_sel[1]}} & mem_product)
                          | ({32{fwd_rs1_sel[2]}} & fwd_mem_wb);
  assign rs2 = in.rs2_val | ({32{fwd_rs2_sel[0]}} & fwd_ex_mem)
                          | ({32{fwd_rs2_sel[1]}} & mem_product)
                          | ({32{fwd_rs2_sel[2]}} & fwd_mem_wb);

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    alu_a = in.ctrl.is_auipc ? in.pc  : rs1;
    alu_b = in.ctrl.alu_src  ? in.imm : rs2;
  end

  logic [31:0] alu_result;
  logic div_req_ready, div_result_valid;
  assign is_div = in.valid && (in.ctrl.alu_op == ALU_DIV  || in.ctrl.alu_op == ALU_DIVU ||
                               in.ctrl.alu_op == ALU_REM  || in.ctrl.alu_op == ALU_REMU);
  assign div_wait = is_div && !div_result_valid;

  alu u_alu (
    .clock            (clock),
    .reset            (reset),
    .mul_issue        (is_mul && !stall && !reset),
    .mul_rs1          (rs1),
    .mul_rs2          (rs2),
    .mem_product      (mem_product),
    .div_req_valid    (is_div && !stall),
    .div_req_ready    (div_req_ready),
    .div_result_valid (div_result_valid),
    .div_result_ready (!stall),
    .div_result       (div_result),
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] jalr_target;
  logic        less_than;
  assign mem_addr = rs1 + in.imm;

  always_comb begin
    less_than = rs1[31] == rs2[31] ? rs1[30:0] < rs2[30:0]
                                    : rs1[31] ^ in.ctrl.branch_op[1];
    branch_cond = (in.ctrl.branch_op[2] ? less_than : rs1 == rs2) ^ in.ctrl.branch_op[0];
    branch_taken  = in.ctrl.is_branch && branch_cond;
    branch_target = in.pc + in.imm;
    // JALR clears bit 0 (RV spec); JAL uses imm directly.
    jalr_target = {mem_addr[31:1], 1'b0};
  end

  // ── Misaligned branch / jump target trap ──────────────────────────────
  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, continue at PC+4, and suppress the link write.
  logic misalign_branch;
  logic misalign_jump;
  logic misalign_fault;
  ctrl_t ctrl_with_trap;

  always_comb begin
    misalign_branch = branch_taken && in.imm[1];
    misalign_jump   = in.ctrl.is_jump && (in.ctrl.is_jalr ? jalr_target[1] : in.imm[1]);
    misalign_fault  = misalign_branch || misalign_jump;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  logic advancing, take_direct, take_indirect;
  logic wrong_direction_q, wrong_target_q, check_q, fence_q;
  logic [31:0] resolved_pc;
  // Decode holds its selects throughout a divide. Only a faulting link
  // can cancel an otherwise enabled EX register write on an advancing edge.
  assign writes_rd = in.valid && in.ctrl.reg_write && !misalign_jump;
  // A valid branch or jump is always a single-cycle EX operation.
  assign advancing       = in.valid && !stall && !reset;
  // EX checks direction and both destinations in parallel. The registered
  // checks select recovery at fetch and squash the younger ID/EX slot.
  always_ff @(posedge clock) begin
    wrong_direction_q <= (take_direct || take_indirect) != forecast_used;
    wrong_target_q    <= forecast_used && (in.ctrl.is_jalr ? jalr_target != forecast_pc
                                                          : branch_target != forecast_pc);
    check_q          <= advancing && (in.ctrl.is_jump || in.ctrl.is_branch);
    fence_q          <= advancing && in.instr[6:0] == 7'h0f && in.instr[14:12] == 3'b001;
  end
  assign redirect = fence_q || (check_q && (wrong_direction_q || wrong_target_q));
  assign take_direct     = !in.imm[1] && (branch_taken || (in.ctrl.is_jump && !in.ctrl.is_jalr));
  assign take_indirect   = in.ctrl.is_jalr && !jalr_target[1];
  assign resolved_pc     = ({32{take_direct}} & branch_target) |
                           ({32{take_indirect}} & jalr_target) |
                           ({32{!(take_direct || take_indirect)}} & fallthrough_pc);

  assign train_en    = advancing && in.ctrl.is_branch && !misalign_fault;
  assign train_index = in.pc[7:2];
  always_comb begin
    if (branch_cond != in.imm[31])
      train_value = in.train_count == 2'b11 ? 2'b11 : in.train_count + 2'd1;
    else
      train_value = in.train_count == 2'b00 ? 2'b00 : in.train_count - 2'd1;
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
      reg_q.is_mul        <= is_mul;
      reg_q.is_div        <= is_div;
      reg_q.mem_addr      <= mem_addr;
      // The EX/MEM bypass slot carries jump link addresses and formatted
      // load candidates. Only a verified load can bypass to its consumer.
      reg_q.alu_result    <= ({32{in.ctrl.is_jump}} & fallthrough_pc) |
                             ({32{in.ctrl.mem_read}} & format_load(early_word, mem_addr[1:0],
                                                                in.ctrl.mem_width, in.ctrl.mem_sext)) |
                             ({32{!(in.ctrl.is_jump || in.ctrl.mem_read)}} & alu_result);
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      // Capture both forwarded operands on issue, while their writers
      // are still in MEM/WB. Keep them through the result transfer.
      if (div_req_ready) begin
        reg_q.rs1_val    <= rs1;
        reg_q.rs2_val    <= rs2;
        reg_q.write_data <= rs2;
      end
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect.
      reg_q.pc_next       <= resolved_pc;
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.ctrl          <= in.valid && !div_wait ? ctrl_with_trap : '0;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid && !div_wait;
    end
  end

  assign out = reg_q;

endmodule
