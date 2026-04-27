// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// Multi-cycle divide handshake: when a DIV/DIVU/REM/REMU op enters EX,
// this stage drives the ALU's start_div for one cycle, then asserts
// `div_busy` to the hazard unit until the divide completes
// (combinationally for the b==0 / INT_MIN-÷-1 edge cases, or 33 cycles
// later for a real iterative divide). The EX/MEM register only captures
// on the cycle the divide completes — preserving rvfi_order +1
// monotonicity, since the MEM/WB retirement boundary advances exactly
// once per divide.
//
// Forwarding select encoding (driven by forward_unit):
//   00 = ID/EX register value (no forward)
//   01 = EX/MEM aluResult (instruction immediately ahead in MEM)
//   10 = MEM/WB result (instruction two ahead, post regfile-write mux)
//
// Latency:        1 cycle for non-div ops; 33 cycles for real divides
//                 (1 cycle for div edge cases).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM (dmem stall)
  input  id_ex_t   in,
  input  logic [1:0]         fwd_rs1_sel,
  input  logic [1:0]         fwd_rs2_sel,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // WB-stage write-data mux output
  output ex_mem_t  out,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               div_busy       // -> hazard_unit (stalls IF/ID/EX/MEM)
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

  // ── Divider handshake state ───────────────────────────────────────────
  // Two flops break the combinational loop between ex_stage's start_div
  // (drives alu) and alu's div_busy (would otherwise gate start_div):
  //   div_started_q   : 1 from the posedge after the start pulse, until
  //                     EX/MEM captures the divide result.
  //   div_completed_q : remembers div_done seen during a stall cycle so
  //                     the divide isn't restarted while waiting for a
  //                     concurrent dmem stall to clear.
  logic        div_started_q;
  logic        div_completed_q;
  logic        is_div_op;
  logic        start_div_w;
  logic        alu_div_busy;
  logic        alu_div_done;
  logic        div_pipeline_stall;
  logic        ex_capture;

  always_comb begin
    is_div_op   = in.valid
                && (in.ctrl.alu_op == ALU_DIV  || in.ctrl.alu_op == ALU_DIVU
                 || in.ctrl.alu_op == ALU_REM  || in.ctrl.alu_op == ALU_REMU);
    // Pulse start exactly once per divide instruction. div_started_q
    // goes high on the next edge so the pulse self-extinguishes; if a
    // dmem stall delays capture and the pulse already happened,
    // div_completed_q latches the done so we don't re-trigger.
    start_div_w = is_div_op && !div_started_q && !div_completed_q;
    // Stall while a divide is in flight. Once we've seen done (live or
    // remembered) the pipeline can advance, subject to the dmem `stall`
    // input from hazard_unit.
    div_pipeline_stall = is_div_op && !div_completed_q && !alu_div_done;
    // EX/MEM register captures only when neither dmem nor divide stalls.
    ex_capture = !stall && !div_pipeline_stall;
  end

  logic [31:0] alu_result;
  alu u_alu (
    .clock     (clock),
    .reset     (reset),
    .start_div (start_div_w),
    .op        (in.ctrl.alu_op),
    .a         (alu_a),
    .b         (alu_b),
    .div_busy  (alu_div_busy),
    .div_done  (alu_div_done),
    .out       (alu_result)
  );

  // alu_div_busy is exposed for completeness/future debug but ex_stage's
  // own div_pipeline_stall is the gating-relevant signal.
  /* verilator lint_off UNUSEDSIGNAL */
  logic _alu_div_busy_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign _alu_div_busy_unused = alu_div_busy;

  assign div_busy = div_pipeline_stall;

  always_ff @(posedge clock) begin
    if (reset) begin
      div_started_q   <= 1'b0;
      div_completed_q <= 1'b0;
    end else if (ex_capture && is_div_op) begin
      // The divide just retired into EX/MEM — clear both trackers.
      div_started_q   <= 1'b0;
      div_completed_q <= 1'b0;
    end else begin
      if (alu_div_done)  div_completed_q <= 1'b1;
      if (start_div_w)   div_started_q   <= 1'b1;
    end
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

  assign redirect        = (branch_taken || in.ctrl.is_jump) && !misalign_fault;
  assign redirect_target = in.ctrl.is_jump ? jump_target : branch_target;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (!ex_capture) begin
      // dmem stall or divide stall: hold EX/MEM. The in-flight LOAD/STORE
      // (or DIV/REM) keeps its slot in the pipeline.
      reg_q <= reg_q;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= rs1;
      reg_q.rs2_val       <= rs2;
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
