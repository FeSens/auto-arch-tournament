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
// Latency:        1 cycle for ordinary work. Divide computes on eight
//                 edges, then transfers its retained result into EX/MEM.
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
  output logic               div_wait,      // hold IF/ID, drain older stages
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               resolve_valid,
  output logic [31:0]        resolve_pc,
  output logic [31:0]        resolve_target,
  output logic               resolve_branch,
  output logic               resolve_jump,
  output logic               resolve_taken,
  output logic               resolve_legal
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
  logic is_div;
  logic div_req_valid, div_req_ready, div_result_valid, div_result_ready;
  logic [31:0] div_rs1_q, div_rs2_q;

  assign is_div = in.valid && !in.ctrl.is_illegal
               && (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU
                   || in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU);
  assign div_req_valid = is_div && !stall && !reset;
  assign div_result_ready = is_div && !stall && !reset;
  assign div_wait = is_div && !div_result_valid;

  // The request stays offered while ID/EX is held. The engine deasserts
  // req_ready while busy AND while retaining a result, so consumption
  // cannot also relaunch the same instruction. ID/EX advances on that edge.

  // ID/EX retains instruction metadata, but its register-file snapshots can
  // be stale. Preserve both accepted post-forward values before WB drains.
  always_ff @(posedge clock) begin
    if (reset) begin
      div_rs1_q <= 32'b0;
      div_rs2_q <= 32'b0;
    end else if (div_req_valid && div_req_ready) begin
      div_rs1_q <= rs1;
      div_rs2_q <= rs2;
    end
  end

  alu u_alu (
    .clock (clock),
    .reset (reset),
    .div_req_valid (div_req_valid),
    .div_req_ready (div_req_ready),
    .div_result_valid (div_result_valid),
    .div_result_ready (div_result_ready),
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
  // instruction, resolve to PC+4 (recovering any prediction), and clear
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

  logic [31:0] actual_next_pc;

  always_comb begin
    actual_next_pc = in.pc + 32'd4;
    if (!ctrl_with_trap.is_illegal) begin
      if (in.ctrl.is_jump) actual_next_pc = jump_target;
      else if (branch_taken) actual_next_pc = branch_target;
    end
  end

  // A prediction is advisory, including on non-control instructions and
  // traps. Comparing exact destinations also catches changing JALR targets.
  // Resolve only on advancement, including a completed divide's stale
  // prediction recovery. Neither a memory hold nor a divide wait trains.
  assign resolve_valid  = in.valid && !stall && !div_wait && !reset;
  assign resolve_pc     = in.pc;
  assign resolve_target = in.ctrl.is_jump ? jump_target : branch_target;
  assign resolve_branch = in.ctrl.is_branch;
  assign resolve_jump   = in.ctrl.is_jump;
  assign resolve_taken  = branch_taken;
  assign resolve_legal  = !ctrl_with_trap.is_illegal;
  assign redirect        = resolve_valid && (actual_next_pc != in.predicted_next_pc);
  assign redirect_target = actual_next_pc;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (div_wait) begin
      // Older work drains once. Clear the ENTIRE bundle: the bus and
      // forwarding muxes consult controls even when valid is zero.
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
      reg_q.write_data    <= is_div ? div_rs2_q : rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= is_div ? div_rs1_q : rs1;
      reg_q.rs2_val       <= is_div ? div_rs2_q : rs2;
      // RVFI always receives the resolved architectural next PC.
      reg_q.pc_next       <= actual_next_pc;
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
