// rtl/ex_stage.sv
//
// Execute stage. Consumes fully forwarded ID/EX operands, runs the ALU,
// resolves branches and computes the redirect target. Owns EX/MEM and
// exports the current architectural write result to ID operand capture.
//
// Latency:        MUL completes in MEM; DIV/REM capture, prepare, six digits.
//                 Older stages drain while the divide holds ID/EX. Its
//                 registered completion transfers at t8 when MEM is ready.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  output logic [31:0]        fwd_data,
  output logic               fwd_w_en,
  output ex_mem_t  out,
  output logic               execute_wait,
  output logic               ex_multiply,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               train_valid,
  output logic [3:0]         train_index,
  output logic               train_agree
);

  // Operands were resolved before ID/EX and stay complete through holds.
  logic [31:0] rs1;
  logic [31:0] rs2;

  assign rs1 = in.rs1_val;
  assign rs2 = in.rs2_val;

  // Prepare the complete memory request from registered source operands,
  // independently of the scalar ALU's operand and architectural-result muxes.
  logic [31:0] memory_address, memory_write_data;
  logic [3:0] memory_mask;
  logic memory_misaligned;

  always_comb begin
    memory_address = in.rs1_val + in.imm;
    case (in.ctrl.mem_width)
      2'd0: begin
        memory_write_data = {4{in.rs2_val[7:0]}};
        memory_mask = 4'b0001 << memory_address[1:0];
      end
      2'd1: begin
        memory_write_data = {2{in.rs2_val[15:0]}};
        memory_mask = 4'b0011 << memory_address[1:0];
      end
      default: begin
        memory_write_data = in.rs2_val;
        memory_mask = 4'b1111;
      end
    endcase
    memory_misaligned = (in.ctrl.mem_width == 2'd2 && memory_address[1:0] != 2'b00) ||
                        (in.ctrl.mem_width == 2'd1 && memory_address[0]);
  end

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    alu_a = in.ctrl.is_auipc ? in.pc  : rs1;
    alu_b = in.ctrl.alu_src  ? in.imm : rs2;
  end

  logic [31:0] alu_result;
  logic [65:0] product;
  logic is_divide, divide_started_q;
  logic div_req_valid, div_req_ready, div_result_valid, div_result_ready;
  logic [31:0] div_result;
  logic [31:0] div_rs1_q, div_rs2_q;

  assign ex_multiply = in.valid && !in.ctrl.is_illegal &&
                       in.ctrl.alu_op >= ALU_MUL && in.ctrl.alu_op <= ALU_MULHSU;
  assign is_divide = in.valid && !in.ctrl.is_illegal &&
                    (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU ||
                     in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU);
  // Load-use interlocking captures MEM load data into ID/EX before this
  // request. Starting during an older memory stall is safe: both operands
  // are already complete, and the existing launch snapshots retain them.
  assign div_req_valid = is_divide && !divide_started_q;
  assign div_result_ready = divide_started_q && is_divide && !stall;
  assign execute_wait = is_divide && !(div_result_valid && div_result_ready);

  always_ff @(posedge clock) begin
    if (reset) begin
      divide_started_q <= 1'b0;
      div_rs1_q <= 32'b0;
      div_rs2_q <= 32'b0;
    end else if (div_req_valid && div_req_ready) begin
      divide_started_q <= 1'b1;
      div_rs1_q <= rs1;
      div_rs2_q <= rs2;
    end else if (div_result_valid && div_result_ready) begin
      divide_started_q <= 1'b0;
    end
  end

  alu u_alu (
    .clock (clock),
    .reset (reset),
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .m_a (rs1),
    .m_b (rs2),
    .out (alu_result),
    .product (product),
    .div_req_valid (div_req_valid),
    .div_req_ready (div_req_ready),
    .div_result_valid (div_result_valid),
    .div_result_ready (div_result_ready),
    .div_result (div_result)
  );

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
    branch_taken  = in.valid && in.ctrl.is_branch && branch_cond;
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
  logic misalign_branch;
  logic misalign_jump;
  logic misalign_fault;
  ctrl_t ctrl_with_trap;

  always_comb begin
    misalign_branch = in.ctrl.is_branch && branch_taken
                      && (branch_target[1:0] != 2'b00);
    misalign_jump   = in.valid && in.ctrl.is_jump && (jump_target[1:0] != 2'b00);
    misalign_fault  = misalign_branch || misalign_jump;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  // Every predicted target is exact and aligned, so only the captured
  // direction needs checking. A held branch neither recovers nor trains
  // until it advances; control transfers cannot be DIV/REM instructions.
  logic effective_taken;
  logic control_advance;
  logic fence_i, fence_i_advance;
  // FENCE.I serializes after older memory completes, then discards any
  // prefetched successors. Ordinary FENCE retains its existing behavior.
  assign fence_i = in.instr[6:0] == 7'b0001111 && in.instr[14:12] == 3'b001;
  assign fence_i_advance = !reset && in.valid && !in.ctrl.is_illegal && !stall && fence_i;
  assign effective_taken = (branch_taken || in.ctrl.is_jump) && !misalign_fault;
  assign control_advance = !reset && in.valid && !in.ctrl.is_illegal && !stall &&
                           (in.ctrl.is_branch || in.ctrl.is_jump);
  assign redirect = fence_i_advance ||
                    (control_advance && (effective_taken != in.predicted_taken));
  // On a mismatch, a saved taken prediction means the actual successor
  // is PC+4. Select with that registered bit to keep the direction compare
  // out of the target-data mux; pc_next below remains fully architectural.
  assign redirect_target = (in.predicted_taken || fence_i) ? (in.pc + 32'd4)
                           : in.ctrl.is_jalr ? jump_target : branch_target;
  assign train_valid = control_advance && in.ctrl.is_branch && !misalign_branch;
  assign train_index = in.pc[5:2];
  assign train_agree = (branch_cond == in.imm[31]);

  // This tap uses only registered ID/EX state and the ALU/divider. Loads
  // and multiplies cannot supply data until MEM; the load-use interlock
  // defers their consumer's capture until MEM has the registered result.
  // A completed divide can supply ID on its existing t8 transfer edge.
  assign fwd_data = is_divide ? div_result
                    : in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
  assign fwd_w_en = in.valid && ctrl_with_trap.reg_write && !in.ctrl.mem_read
                    && !ex_multiply
                    && (!is_divide || div_result_valid);

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (execute_wait) begin
      // The older EX/MEM entry advances to MEM/WB on this edge. Replace
      // it with a bubble. Retained payload is inert without validity.
      reg_q.valid <= 1'b0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= fwd_data;
      reg_q.mem_address   <= memory_address;
      reg_q.mem_mask      <= memory_mask;
      reg_q.mem_misaligned <= memory_misaligned;
      reg_q.product       <= product;
      reg_q.multiply      <= ex_multiply;
      reg_q.multiply_high <= (in.ctrl.alu_op != ALU_MUL);
      reg_q.write_data    <= memory_write_data;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= is_divide ? div_rs1_q : rs1;
      reg_q.rs2_val       <= is_divide ? div_rs2_q : rs2;
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

  assign out = reg_q;

endmodule
