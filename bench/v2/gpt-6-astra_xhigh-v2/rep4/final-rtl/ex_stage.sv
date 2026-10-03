// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// Forwarding select encoding (driven by forward_unit):
//   00 = ID/EX register value (no forward)
//   01 = EX/MEM aluResult (instruction immediately ahead in MEM)
//   10 = MEM/WB registered completed result (instruction two ahead)
//
// Latency:        1 cycle normally; division retires directly after eight
//                 busy iterations, bypassing the memory pipeline.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  logic               normal_wb_valid, // older retirement has priority
  // Saved predicted_next_pc remains available for equivalence validation;
  // recovery uses the predecoded tokens instead of this wide field.
  /* verilator lint_off UNUSEDSIGNAL */
  input  id_ex_t   in,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [1:0]         fwd_rs1_sel,
  input  logic [1:0]         fwd_rs2_sel,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // MEM/WB completed result
  output ex_mem_t  out,
  output mem_wb_t  div_completion,
  output logic               next_ex_mem_w_en,
  output logic               execute_wait,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               branch_update,
  output logic [31:0]        branch_pc,
  output logic               branch_outcome
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

  logic [31:0] alu_result, div_result;
  logic [31:0] effective_addr;
  logic is_divide, div_request, div_consume, div_busy, div_done;
  logic is_multiply;
  logic advance;
  logic [31:0] div_rs1_q, div_rs2_q;

  assign is_multiply = in.ctrl.alu_op == ALU_MUL || in.ctrl.alu_op == ALU_MULH
                   || in.ctrl.alu_op == ALU_MULHU || in.ctrl.alu_op == ALU_MULHSU;
  assign is_divide = in.valid && (in.ctrl.alu_op == ALU_DIV
                   || in.ctrl.alu_op == ALU_DIVU || in.ctrl.alu_op == ALU_REM
                   || in.ctrl.alu_op == ALU_REMU);
  // A blocked older memory request retains both its payload and the WB
  // forwarding source. Capture operands only on the edge that drains it.
  assign div_request = is_divide && !reset && !stall && !div_busy && !div_done;
  // Ordinarily all older entries drain before completion. If an older
  // WB is still present, retain completion and retire that entry first.
  assign execute_wait = is_divide && (!div_done || normal_wb_valid);
  assign advance = in.valid && !reset && !stall && !execute_wait;
  assign div_consume = is_divide && advance;
  assign effective_addr = rs1 + in.imm;

  // ID/EX holds instruction metadata until consumption. Operand values
  // must come from launch capture, since older forwarding entries drain.
  // The result depends only on registered divider state, never alu_result
  // or the live EX forwarding inputs.
  always_comb begin
    div_completion = '0;
    div_completion.pc = in.pc;
    div_completion.pc_next = in.pc + 32'd4;
    div_completion.instr = in.instr;
    div_completion.ctrl = in.ctrl;
    div_completion.rd = in.rd;
    div_completion.rs1_addr = in.rs1_addr;
    div_completion.rs2_addr = in.rs2_addr;
    div_completion.rs1_val = div_rs1_q;
    div_completion.rs2_val = div_rs2_q;
    div_completion.alu_result = div_result;
    div_completion.valid = div_consume;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      div_rs1_q <= 32'b0;
      div_rs2_q <= 32'b0;
    end else if (div_request) begin
      div_rs1_q <= rs1;
      div_rs2_q <= rs2;
    end
  end

  alu #(.ENABLE_MULTIPLY(1'b0)) u_alu (
    .clock (clock),
    .reset (reset),
    .div_request (div_request),
    .div_consume (div_consume),
    .div_busy (div_busy),
    .div_done (div_done),
    .div_result (div_result),
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond, branch_base;
  logic [31:0] branch_rs1, branch_rs2;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] jump_target;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] jalr_sum;  // bit 0 deliberately dropped per RV JALR spec
  /* verilator lint_on UNUSEDSIGNAL */

  // Bias signed operands into unsigned order; unsigned branches pass
  // through unchanged. The general ALU comparator remains independent.
  assign branch_rs1 = {rs1[31] ^ !in.ctrl.branch_op[1], rs1[30:0]};
  assign branch_rs2 = {rs2[31] ^ !in.ctrl.branch_op[1], rs2[30:0]};
  always_comb begin
    case (in.ctrl.branch_op)
      BR_BEQ, BR_BNE: branch_base = (rs1 == rs2);
      BR_BLT, BR_BGE, BR_BLTU, BR_BGEU:
        branch_base = (branch_rs1 < branch_rs2);
      default: branch_base = 1'b0;
    endcase
    branch_cond = branch_base ^ in.ctrl.branch_op[0];
    if (in.ctrl.branch_op == 3'd2 || in.ctrl.branch_op == 3'd3)
      branch_cond = 1'b0;
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
  // instruction, resolve to fall-through, and clear
  // reg_write so JAL/JALR don't write the return address on trap.
  logic misalign_branch;
  logic misalign_jump;
  logic misalign_fault;
  logic direct_jal, direct_target_misaligned;
  ctrl_t ctrl_with_trap;

  // Ownership on an advancing edge, independently of the result mux.
  // Every divide edge inserts an EX/MEM bubble, including consumption.
  // Multiply operands advance here, but their result belongs only to WB.
  // This is only the speculative owner for the younger ID/EX entry.
  // Every advancing JALR squashes that entry and both forwarding selects;
  // a held JALR disables capture. Its target alignment must not feed this
  // hint. Architectural EX/MEM controls still suppress the link on trap.
  // Other decoded writers retain their existing trap-aware ownership:
  // only a direct JAL can both write and take a direct-target fault.
  assign direct_jal = in.ctrl.is_jump && !in.ctrl.is_jalr;
  assign direct_target_misaligned = branch_target[1:0] != 2'b00;
  assign next_ex_mem_w_en = in.ctrl.reg_write && !is_divide && !is_multiply
                         && !(direct_jal && direct_target_misaligned);

  always_comb begin
    misalign_branch = in.ctrl.is_branch && branch_taken
                      && direct_target_misaligned;
    misalign_jump   = in.ctrl.is_jump && (jump_target[1:0] != 2'b00);
    misalign_fault  = misalign_branch || misalign_jump;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  logic [31:0] actual_next_pc;
  assign actual_next_pc = misalign_fault   ? (in.pc + 32'd4)
                        : in.ctrl.is_jump ? jump_target
                        : branch_taken    ? branch_target
                                          : (in.pc + 32'd4);

  logic direct_miss, indirect_miss;
  // Direct recovery has no dependency on shared JALR misalignment or
  // target arithmetic. Decode already qualified kind, alignment and +4.
  assign direct_miss = in.recovery_static_miss
                    || (in.recovery_branch_check
                        && (branch_base ^ in.branch_prediction_xor));
  // Sequentially predicted JALRs always recover, including PC+4 and
  // misalignment traps. Only the target data retains the forwarded sum.
  assign indirect_miss = in.ctrl.is_jalr && !in.ctrl.is_illegal;

  // Only advancing instructions can recover or train. A held branch
  // must keep its prediction and wait for the older memory transaction.
  assign redirect = advance && (direct_miss || indirect_miss);
  assign redirect_target = actual_next_pc;
  assign branch_update = advance && in.ctrl.is_branch
                      && !in.ctrl.is_illegal && !misalign_branch;
  assign branch_pc = in.pc;
  assign branch_outcome = branch_cond;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (is_divide) begin
      // Older instructions drain during division. Clear controls as well
      // as validity: memory requests and forwarding inspect those fields.
      // Consumption also injects a bubble: the divide retires directly.
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). MEM completes loads and multiplies;
      // ordinary results, including PC+4, pass through unchanged.
      reg_q.alu_result    <= in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
      reg_q.effective_addr <= (in.ctrl.mem_read || in.ctrl.mem_write)
                            ? effective_addr : 32'b0;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= rs1;
      reg_q.rs2_val       <= rs2;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with recovery's actual next PC.
      reg_q.pc_next       <= actual_next_pc;
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.is_multiply   <= is_multiply;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
