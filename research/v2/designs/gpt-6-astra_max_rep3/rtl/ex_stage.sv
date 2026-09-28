// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// Forwarding select encoding (driven by forward_unit):
//   00 = ID/EX register value (no forward)
//   01 = EX/MEM aluResult (instruction immediately ahead in MEM)
//   10 = MEM/WB result (instruction two ahead, post regfile-write mux)
//
// Latency:        1 cycle normally; division waits for its registered response.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  input  logic [1:0]         fwd_rs1_sel,
  input  logic [1:0]         fwd_rs2_sel,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // WB-stage write-data mux output
  output ex_mem_t  out,
  output logic               div_wait,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               branch_train_valid,
  output logic [3:0]        branch_train_index,
  output logic [5:0]        branch_train_tag,
  output logic               branch_train_agree
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

  logic [31:0] alu_result;
  logic [31:0] div_result;
  logic is_div, div_request, div_consume, div_busy, div_valid;

  assign is_div = in.valid && !in.ctrl.is_illegal &&
                  (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU ||
                   in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU);
  // The older EX/MEM instruction must be able to advance on acceptance.
  assign div_request = is_div && !div_busy && !stall && !reset;
  assign div_consume = div_valid && !stall && !reset;
  assign div_wait = (is_div || div_busy) && !div_valid;

  alu u_alu (
    .clock(clock), .reset(reset),
    .div_request(div_request), .div_consume(div_consume),
    .div_busy(div_busy), .div_valid(div_valid), .div_result(div_result),
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result)
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
  assign actual_transfer = !in.ctrl.is_illegal && !misalign_fault &&
                           (branch_taken || in.ctrl.is_jump);
  // Direct targets are recomputed from the same PC/instruction as IF, so
  // only direction can disagree. A correct prediction keeps the younger
  // target instruction; a predicted-taken loop exit recovers to PC+4.
  // A held EX instruction cannot recover until it actually advances.
  assign redirect = in.valid && !reset && !stall && !div_wait &&
                    (in.pred_taken != actual_transfer);
  assign redirect_target = actual_transfer
                         ? (in.ctrl.is_jump ? jump_target : branch_target)
                         : (in.pc + 32'd4);

  // Every legal, nontrapping conditional branch trains exactly when EX
  // advances, whether prediction was correct or recovery is asserted.
  // Use the fully forwarded condition and this instruction's static bias,
  // independently of the direction saved at fetch acceptance.
  assign branch_train_valid = in.valid && !reset && !stall && !div_wait &&
                              in.ctrl.is_branch && !in.ctrl.is_illegal &&
                              !misalign_fault;
  assign branch_train_index = in.pc[5:2] ^ in.pc[10:7];
  assign branch_train_tag = in.pc[11:6];
  assign branch_train_agree = (branch_cond == in.instr[31]);

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;
  ex_mem_t next_ex, div_meta_q;

  always_comb begin
    next_ex = '0;
    next_ex.pc            = in.pc;
    next_ex.alu_result    = in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
    next_ex.write_data    = rs2;
    next_ex.rd            = in.rd;
    next_ex.rs1_addr      = in.rs1_addr;
    next_ex.rs2_addr      = in.rs2_addr;
    next_ex.rs1_val       = rs1;
    next_ex.rs2_val       = rs2;
    next_ex.pc_next       = redirect_target;  // actual architectural next PC
    next_ex.branch_taken  = branch_taken;
    next_ex.branch_target = branch_target;
    next_ex.ctrl          = ctrl_with_trap;
    next_ex.instr         = in.instr;
    next_ex.valid         = in.valid;
  end

  // Capture fully forwarded source data, including RVFI originals, before
  // older producers disappear from MEM/WB during the divider's work clocks.
  always_ff @(posedge clock) begin
    if (reset) div_meta_q <= '0;
    else if (div_request) begin
      div_meta_q <= next_ex;
      div_meta_q.alu_result <= 32'b0;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (div_consume) begin
      reg_q <= div_meta_q;
      reg_q.alu_result <= div_result;
    end else if (div_wait) begin
      // The older entry advanced to MEM/WB on this edge. Holding it here
      // would repeat stores/retirements. Clear valid AND every side effect.
      reg_q <= '0;
    end else reg_q <= next_ex;
  end

  assign out = reg_q;

endmodule
