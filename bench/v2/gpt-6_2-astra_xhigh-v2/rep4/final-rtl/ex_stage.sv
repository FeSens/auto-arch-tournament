// rtl/ex_stage.sv
//
// Execute uses collected operands plus a bypass from the immediate
// predecessor. It resolves redirects and owns the EX/MEM register.
//
// Latency:        1 cycle to EX/MEM, or 8 for divide/remainder.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  input  logic               bypass_rs1,
  input  logic               bypass_rs2,
  input  logic               bypass_alu_a, bypass_alu_b,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic               repair,
  input  logic [31:0]        candidate,
  input  logic [31:1]        expected_base, expected_base_carry,
  input  logic [31:0]        branch_target, sequential_pc,
  input  logic               redirect_on_taken, redirect_on_fallthrough, redirect_always,
  output logic               bypass_writer,
  output logic [31:0]        effective_addr,
  output ex_mem_t  out,
  output logic               div_wait,
  output logic [31:0]        div_result,
  output btb_update_t        update,
  output logic               redirect,
  output logic [31:0]        redirect_target
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;
  assign rs1 = in.rs1_val | ({32{bypass_rs1}} & fwd_ex_mem);
  assign rs2 = in.rs2_val | ({32{bypass_rs2}} & fwd_ex_mem);

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    alu_a = (in.ctrl.is_auipc ? in.pc : in.rs1_val) | ({32{bypass_alu_a}} & fwd_ex_mem);
    alu_b = (in.ctrl.alu_src ? in.imm : in.rs2_val) | ({32{bypass_alu_b}} & fwd_ex_mem);
  end

  logic [31:0] alu_result;
  logic [63:0] product;
  logic [31:0] div_rs1_q, div_rs2_q;
  logic        is_div, div_start, div_busy, div_last, div_done;

  assign is_div = in.valid && (in.ctrl.alu_op == ALU_DIV  || in.ctrl.alu_op == ALU_DIVU ||
                               in.ctrl.alu_op == ALU_REM  || in.ctrl.alu_op == ALU_REMU);
  assign div_start = is_div && !div_busy && !stall && !repair;
  assign div_wait  = is_div && !(div_last || div_done);

  // The adjacent writer can drain while the divider owns EX.
  always_ff @(posedge clock) begin
    if (div_start) begin
      div_rs1_q <= rs1;
      div_rs2_q <= rs2;
    end
  end

  alu u_alu (
    .clock      (clock),
    .reset      (reset),
    .div_start  (div_start),
    .div_accept (!stall),
    .div_busy   (div_busy),
    .div_last   (div_last),
    .div_done   (div_done),
    .div_result (div_result),
    .result_sel (in.result_sel),
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result)
  );

  multiplier u_mul (
    .op      (in.ctrl.alu_op),
    .lhs_ext (in.mul_lhs_signed && rs1[31]),
    .rhs_ext (in.mul_rhs_signed && rs2[31]),
    .a       (rs1),
    .b       (rs2),
    .product (product)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] control_target;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] jalr_sum;  // bit 0 deliberately dropped per RV JALR spec
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    case (in.ctrl.branch_op)
      BR_BEQ:  branch_cond = rs1 == rs2;
      BR_BNE:  branch_cond = rs1 != rs2;
      BR_BLT:  branch_cond = ($signed(rs1) <  $signed(rs2));
      BR_BGE:  branch_cond = ($signed(rs1) >= $signed(rs2));
      BR_BLTU: branch_cond = (rs1 <  rs2);
      BR_BGEU: branch_cond = (rs1 >= rs2);
      default: branch_cond = 1'b0;
    endcase
    branch_taken  = in.ctrl.is_branch && branch_cond;
    // JALR clears bit 0. Direct jumps and conditional branches use PC.
    jalr_sum    = rs1 + in.imm;
    control_target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0} : branch_target;
  end

  // ── Misaligned branch / jump target trap ──────────────────────────────
  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, continue at PC+4, and suppress the link write.
  logic wants_transfer;
  logic misalign_fault;
  logic data_fault, link_fault;
  logic taken;
  logic advancing;
  logic fence_i;
  ctrl_t ctrl_with_trap;

  assign wants_transfer = branch_taken || in.ctrl.is_jump;
  assign misalign_fault = wants_transfer && control_target[1:0] != 0;
  assign link_fault = in.ctrl.is_jump && control_target[1:0] != 0;
  assign data_fault = (in.ctrl.mem_read || in.ctrl.mem_write) &&
                      ((in.ctrl.mem_width == 2'd1 && effective_addr[0]) ||
                       (in.ctrl.mem_width == 2'd2 && effective_addr[1:0] != 0));
  assign taken = wants_transfer && !misalign_fault;
  assign advancing = in.valid && !stall && !div_wait && !repair;
  assign fence_i = in.instr[6:0] == 7'h0f && in.instr[14:12] == 3'b001;

  always_comb begin
    ctrl_with_trap = in.ctrl;
    ctrl_with_trap.reg_write = in.valid && in.ctrl.reg_write && !link_fault && !data_fault;
    ctrl_with_trap.mem_read  = in.valid && in.ctrl.mem_read && !data_fault;
    ctrl_with_trap.mem_write = in.valid && in.ctrl.mem_write && !data_fault;
    if (misalign_fault || data_fault)
      ctrl_with_trap.is_illegal = 1'b1;
  end

  assign effective_addr = rs1 + in.imm;
  // Collection selects the adjacent writer while EX checks alignment.
  // A fault refetches the consumer so it reads the surviving rd value.
  assign bypass_writer = in.valid && in.ctrl.reg_write;

  assign redirect_target = taken ? control_target : sequential_pc;
  wire jalr_match = (rs1[0] && in.imm[0]) ? rs1[31:1] == expected_base_carry :
                                             rs1[31:1] == expected_base;
  wire bad_jalr = in.ctrl.is_jalr && (in.prediction.taken ? !jalr_match : !jalr_sum[1]);
  assign redirect = advancing && (redirect_always || bad_jalr || link_fault || data_fault ||
                    (branch_cond ? redirect_on_taken : redirect_on_fallthrough));

  // The fetch snapshot belongs to this instruction even if another source
  // has since replaced its entry. Write the tag, word and target together.
  logic ram_pc;
  assign ram_pc = in.pc[31:20] == 0 && in.pc[1:0] == 0;
  assign update.invalidate = advancing && fence_i;
  assign update.successor = advancing && ram_pc && !in.ctrl.is_illegal &&
                            !in.ctrl.is_branch && !in.ctrl.is_jump && !fence_i;
  assign update.write = advancing && (in.ctrl.is_branch || in.ctrl.is_jump) &&
                        !in.ctrl.is_illegal && ram_pc &&
                        control_target[31:20] == 0 && control_target[1:0] == 0;
  assign update.pc     = in.pc[19:2];
  assign update.target = control_target[19:2];
  assign update.instr  = in.instr;
  always_comb begin
    if (in.ctrl.is_jump)
      update.counter = 2'b11;
    else if (!in.prediction.hit)
      update.counter = branch_taken ? 2'b10 : 2'b01;
    else if (branch_taken)
      update.counter = in.prediction.counter == 2'b11 ? 2'b11 : in.prediction.counter + 2'd1;
    else
      update.counter = in.prediction.counter == 2'b00 ? 2'b00 : in.prediction.counter - 2'd1;
  end

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (!stall) begin
      reg_q.pc            <= in.pc;
      reg_q.alu_result    <= in.use_mul_low ? product[31:0] :
                             alu_result | ({32{in.ctrl.is_jump}} & sequential_pc) |
                             ({32{in.ctrl.mem_read}} & format_load(candidate,
                               effective_addr[1:0], in.ctrl.mem_width, in.ctrl.mem_sext));
      reg_q.mul_high      <= product[63:32];
      reg_q.use_mul_high  <= in.use_mul_high;
      reg_q.use_div       <= is_div;
      reg_q.use_alu_result <= !in.use_mul_high && !is_div && !in.ctrl.mem_to_reg;
      reg_q.mem_addr      <= effective_addr;
      reg_q.ram_access    <= effective_addr[31:20] == 0;
      reg_q.serialize     <= ctrl_with_trap.is_illegal || in.instr[6:0] == 7'h0f ||
                             in.instr[6:0] == 7'h73;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= is_div ? div_rs1_q : rs1;
      reg_q.rs2_val       <= is_div ? div_rs2_q : rs2;
      reg_q.pc_next       <= redirect_target;
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
    end
    if (reset || (!stall && (div_wait || repair))) begin
      reg_q.valid          <= 1'b0;
      reg_q.ctrl.reg_write <= 1'b0;
      reg_q.ctrl.mem_read  <= 1'b0;
      reg_q.ctrl.mem_write <= 1'b0;
    end
  end

  assign out = reg_q;

endmodule
