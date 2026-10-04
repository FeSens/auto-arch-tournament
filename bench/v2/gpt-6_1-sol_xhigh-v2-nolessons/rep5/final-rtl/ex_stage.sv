// rtl/ex_stage.sv
//
// Execute stage. Runs the ALU directly from its captured inputs, resolves
// branches and computes redirects. Owns the EX/MEM pipeline register and
// exposes its next result to the decode operand resolver.
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  output ex_mem_t  out,
  output logic               forward_wen,
  output logic [4:0]         forward_rd,
  output logic [31:0]        forward_data,
  output logic               divider_wait,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic              train_valid,
  output logic [5:0]        train_index,
  output logic              train_agree
);

  // Architectural operands are final when admitted to ID/EX, including
  // during waits after the older producer has drained from the pipeline.
  logic [31:0] rs1;
  logic [31:0] rs2;

  assign rs1 = in.rs1_val;
  assign rs2 = in.rs2_val;

  logic [31:0] alu_result;
  alu u_alu (
    .op  (in.ctrl.alu_op),
    .a   (in.alu_a),
    .b   (in.alu_b),
    .out (alu_result)
  );

  // Capture architectural operands and the multiply's retirement payload
  // before ID/EX is held. Internal progress does not depend on MEM ready.
  logic is_mul, mul_start, mul_busy, mul_valid, mul_accept, mul_wait;
  logic [31:0] mul_result;
  ex_mem_t mul_meta_q, mul_meta;

  assign is_mul = in.valid && in.mul_class;
  assign mul_start = is_mul && !mul_busy && !mul_valid;
  assign mul_accept = mul_valid && !stall;
  assign mul_wait = mul_busy || (is_mul && !mul_valid);

  always_comb begin
    mul_meta = '0;
    mul_meta.pc = in.pc;
    mul_meta.write_data = rs2;
    mul_meta.rd = in.rd;
    mul_meta.rs1_addr = in.rs1_addr;
    mul_meta.rs2_addr = in.rs2_addr;
    mul_meta.rs1_val = rs1;
    mul_meta.rs2_val = rs2;
    mul_meta.pc_next = in.fallthrough_pc;
    mul_meta.ctrl = in.ctrl;
    mul_meta.instr = in.instr;
    mul_meta.valid = in.valid;
  end

  mul_unit u_mul (
    .clock(clock), .reset(reset), .start(mul_start),
    .op(in.ctrl.alu_op), .a(rs1), .b(rs2),
    .busy(mul_busy), .result_valid(mul_valid), .result(mul_result),
    .result_accept(mul_accept)
  );

  always_ff @(posedge clock) begin
    if (reset) mul_meta_q <= '0;
    else if (mul_start) mul_meta_q <= mul_meta;
  end

  // Launch exclusively from registered EX operands and retirement metadata.
  // Arithmetic can progress behind an independently held older MEM request;
  // only completed-result acceptance depends on MEM availability.
  logic is_div, div_start;
  logic div_busy, div_valid, div_accept;
  logic [31:0] div_result;
  ex_mem_t div_meta_q, div_meta;

  assign is_div = in.valid && in.div_class;
  assign div_start = is_div && !div_busy && !div_valid
                     && !mul_busy && !mul_valid;
  assign div_accept = div_valid && !stall;
  // Completion releases ID/EX on the result-transfer edge, with no rearm.
  assign divider_wait = div_busy || (is_div && !div_valid) || mul_wait;

  always_comb begin
    div_meta = '0;
    div_meta.pc = in.pc;
    div_meta.write_data = rs2;
    div_meta.rd = in.rd;
    div_meta.rs1_addr = in.rs1_addr;
    div_meta.rs2_addr = in.rs2_addr;
    div_meta.rs1_val = rs1;
    div_meta.rs2_val = rs2;
    div_meta.pc_next = in.fallthrough_pc;
    div_meta.ctrl = in.ctrl;
    div_meta.instr = in.instr;
    div_meta.valid = in.valid;
  end

  div_unit u_div (
    .clock(clock), .reset(reset), .start(div_start),
    .op(in.ctrl.alu_op), .a(rs1), .b(rs2),
    .busy(div_busy), .result_valid(div_valid), .result(div_result),
    .result_accept(div_accept)
  );

  always_ff @(posedge clock) begin
    if (reset) div_meta_q <= '0;
    else if (div_start) div_meta_q <= div_meta;
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
    branch_target = in.direct_target;
    // JALR clears bit 0 (RV spec); JAL uses imm directly.
    jalr_sum    = rs1 + in.imm;
    jump_target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0}
                                  : in.direct_target;
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

  logic actual_transfer;
  assign actual_transfer = (branch_taken || in.ctrl.is_jump)
                           && !in.ctrl.is_illegal && !misalign_fault;
  assign redirect = in.valid && !stall && !divider_wait
                    && (actual_transfer ^ in.predicted_transfer);
  // Only registered instruction kind selects JALR's independent target.
  // Direct corrections use the preselected metadata, without any live
  // branch outcome or architectural pc_next mux on the fetch data path.
  assign redirect_target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0}
                                          : in.recovery_pc;
  assign train_valid = in.valid && !stall && !divider_wait
                       && in.ctrl.is_branch && !in.ctrl.is_illegal && !misalign_fault;
  assign train_index = in.pc[7:2] ^ in.pc[13:8];
  assign train_agree = branch_cond == in.instr[31];

  // The exact result about to enter EX/MEM. Completion and registered EX
  // occupancy alone select data and destination; launch and stall
  // must not enter this path, which feeds younger decode operands.
  // Loads expose no EX candidate because their ALU output is an address.
  always_comb begin
    forward_rd = in.rd;
    forward_data = in.ctrl.is_jump ? in.fallthrough_pc : alu_result;
    // Conditional branches never write a register. Only jump alignment
    // can suppress an otherwise eligible fast result; keep the live
    // branch comparator out of younger decode operand data selection.
    forward_wen = in.valid && in.fast_write && !misalign_jump;
    if (mul_valid) begin
      forward_rd = mul_meta_q.rd;
      forward_data = mul_result;
      forward_wen = mul_meta_q.valid && mul_meta_q.ctrl.reg_write;
    end else if (div_valid) begin
      forward_rd = div_meta_q.rd;
      forward_data = div_result;
      forward_wen = div_meta_q.valid && div_meta_q.ctrl.reg_write;
    end
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
    end else if (mul_accept) begin
      reg_q <= mul_meta_q;
      reg_q.alu_result <= mul_result;
    end else if (div_accept) begin
      reg_q <= div_meta_q;
      reg_q.alu_result <= div_result;
    end else if (mul_wait || is_div || div_busy) begin
      // The old EX/MEM entry advances into MEM/WB on this edge. Clear it
      // completely, so an older store is never reissued during arithmetic.
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= in.ctrl.is_jump ? in.fallthrough_pc : alu_result;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= rs1;
      reg_q.rs2_val       <= rs2;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect.
      reg_q.pc_next       <= misalign_fault     ? in.fallthrough_pc
                            : in.ctrl.is_jump   ? jump_target
                            : branch_taken      ? branch_target
                                                : in.fallthrough_pc;
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
