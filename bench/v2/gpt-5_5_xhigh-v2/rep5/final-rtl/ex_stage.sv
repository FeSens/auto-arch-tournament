// rtl/ex_stage.sv
//
// Two-stage execute block.
//
//   EX1: forwarding selection, branch/jump metadata resolve, and
//        operand/control latch.
//   EX2: ALU, registered redirect/trap selection, iterative divider, and
//        the EX/MEM register update.
//
// Forwarding select encoding (driven by forward_unit):
//   00 = ID/EX register value (no forward)
//   01 = EX/MEM aluResult (registered EX2/MEM producer; never a LOAD)
//   10 = MEM/WB result (WB-stage write-data mux output)
//
// Latency:        2 execute stages for normal ALU ops; iterative DIV/REM
//                 holds EX1/EX2 until iter_divider reports valid.
// RVFI fields:    feeds pc_wdata (= pc_next), rd_wdata for ALU/JAL/JALR,
//                 memory addresses/data, and branch resolution.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM and EX1/EX2 (dmem stall)
  input  logic               flush_ex1,     // redirect/flush kill for younger EX1 payload
  input  logic               bubble_ex1,    // interlock bubble while ID/EX is held
  input  id_ex_t             in,
  input  logic [1:0]         fwd_rs1_sel,
  input  logic [1:0]         fwd_rs2_sel,
  input  logic [31:0]        fwd_ex_mem,    // registered EX2/MEM ALU result
  input  logic [31:0]        fwd_mem_wb,    // WB-stage write-data mux output
  output ex_mem_t            out,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               div_stall,
  output logic [4:0]         ex1_rd,
  output logic               ex1_reg_write,
  output logic               ex1_mem_read
);

  // ── EX1: operand forwarding muxes and register ────────────────────────
  logic [31:0] rs1_sel;
  logic [31:0] rs2_sel;
  logic        ex1_branch_cond;
  logic [31:0] ex1_branch_target;
  logic [31:0] ex1_jump_target;
  logic        ex1_branch_misalign;
  logic        ex1_jump_misalign;
  ex1_ex2_t    ex1_q;
  ex1_ex2_t    ex1_next;
  logic        hold_ex1;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] ex1_jalr_sum;  // bit 0 deliberately dropped per RV JALR spec
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    case (fwd_rs1_sel)
      2'd1:    rs1_sel = fwd_ex_mem;
      2'd2:    rs1_sel = fwd_mem_wb;
      default: rs1_sel = in.rs1_val;
    endcase
    case (fwd_rs2_sel)
      2'd1:    rs2_sel = fwd_ex_mem;
      2'd2:    rs2_sel = fwd_mem_wb;
      default: rs2_sel = in.rs2_val;
    endcase
  end

  always_comb begin
    case (in.ctrl.branch_op)
      BR_BEQ:  ex1_branch_cond = (rs1_sel == rs2_sel);
      BR_BNE:  ex1_branch_cond = (rs1_sel != rs2_sel);
      BR_BLT:  ex1_branch_cond = ($signed(rs1_sel) <  $signed(rs2_sel));
      BR_BGE:  ex1_branch_cond = ($signed(rs1_sel) >= $signed(rs2_sel));
      BR_BLTU: ex1_branch_cond = (rs1_sel <  rs2_sel);
      BR_BGEU: ex1_branch_cond = (rs1_sel >= rs2_sel);
      default: ex1_branch_cond = 1'b0;
    endcase

    ex1_branch_target = in.pc + in.imm;
    ex1_jalr_sum      = rs1_sel + in.imm;
    ex1_jump_target   = in.ctrl.is_jalr ? {ex1_jalr_sum[31:1], 1'b0}
                                        : ex1_branch_target;

    ex1_branch_misalign = in.valid
                        && in.ctrl.is_branch
                        && ex1_branch_cond
                        && (ex1_branch_target[1:0] != 2'b00);
    ex1_jump_misalign   = in.valid
                        && in.ctrl.is_jump
                        && (ex1_jump_target[1:0] != 2'b00);
  end

  always_comb begin
    ex1_next.pc       = in.pc;
    ex1_next.rs1_val  = rs1_sel;
    ex1_next.rs2_val  = rs2_sel;
    ex1_next.imm      = in.imm;
    ex1_next.alu_a    = in.ctrl.is_auipc ? in.pc   : rs1_sel;
    ex1_next.alu_b    = in.ctrl.alu_src  ? in.imm  : rs2_sel;
    ex1_next.branch_cond     = ex1_branch_cond;
    ex1_next.branch_target   = ex1_branch_target;
    ex1_next.jump_target     = ex1_jump_target;
    ex1_next.branch_misalign = ex1_branch_misalign;
    ex1_next.jump_misalign   = ex1_jump_misalign;
    ex1_next.rd       = in.rd;
    ex1_next.rs1_addr = in.rs1_addr;
    ex1_next.rs2_addr = in.rs2_addr;
    ex1_next.ctrl     = in.ctrl;
    ex1_next.instr    = in.instr;
    ex1_next.valid    = in.valid;
  end

  // ── EX2: ALU consumes operands preselected and registered by EX1 ──────
  logic [31:0] alu_result;
  alu u_alu (
    .op  (ex1_q.ctrl.alu_op),
    .a   (ex1_q.alu_a),
    .b   (ex1_q.alu_b),
    .out (alu_result)
  );

  // ── Iterative DIV/REM ─────────────────────────────────────────────────
  // In RISCV_FORMAL_ALTOPS mode the ALU's algebraic stand-ins must remain
  // visible to riscv-formal, so DIV/REM are not intercepted here.
  logic        iter_div_op;
  logic        div_start;
  logic        div_busy;
  logic        div_valid;
  logic        div_consume;
  logic        div_capture;
  logic [31:0] div_result;

  always_comb begin
    iter_div_op = 1'b0;
`ifndef RISCV_FORMAL_ALTOPS
    iter_div_op = ex1_q.valid
               && ((ex1_q.ctrl.alu_op == ALU_DIV)  ||
                   (ex1_q.ctrl.alu_op == ALU_DIVU) ||
                   (ex1_q.ctrl.alu_op == ALU_REM)  ||
                   (ex1_q.ctrl.alu_op == ALU_REMU));
`endif
  end

  assign div_start   = iter_div_op && !div_busy && !div_valid;
  assign div_capture = iter_div_op &&  div_valid && !stall;
  assign div_consume = div_capture;
  assign div_stall   = iter_div_op && (!div_valid || stall);

  iter_divider u_divider (
    .clock   (clock),
    .reset   (reset),
    .start   (div_start),
    .consume (div_consume),
    .op      (ex1_q.ctrl.alu_op),
    .a       (ex1_q.rs1_val),
    .b       (ex1_q.rs2_val),
    .busy    (div_busy),
    .valid   (div_valid),
    .result  (div_result)
  );

  // ── Redirect/trap selection from registered EX1 metadata ──────────────
  logic        branch_taken;
  logic misalign_fault;
  ctrl_t ctrl_with_trap;

  assign branch_taken  = ex1_q.valid && ex1_q.ctrl.is_branch && ex1_q.branch_cond;
  assign misalign_fault = ex1_q.valid
                       && (ex1_q.branch_misalign || ex1_q.jump_misalign);

  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, suppress the redirect (PC stays linear), and clear
  // reg_write so JAL/JALR don't write the return address on trap.
  always_comb begin
    ctrl_with_trap = ex1_q.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  assign redirect        = ex1_q.valid
                         && (branch_taken || ex1_q.ctrl.is_jump)
                         && !misalign_fault;
  assign redirect_target = ex1_q.ctrl.is_jump ? ex1_q.jump_target
                                              : ex1_q.branch_target;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (div_capture) begin
      reg_q.pc            <= ex1_q.pc;
      reg_q.alu_result    <= div_result;
      reg_q.write_data    <= ex1_q.rs2_val;
      reg_q.rd            <= ex1_q.rd;
      reg_q.rs1_addr      <= ex1_q.rs1_addr;
      reg_q.rs2_addr      <= ex1_q.rs2_addr;
      reg_q.rs1_val       <= ex1_q.rs1_val;
      reg_q.rs2_val       <= ex1_q.rs2_val;
      reg_q.pc_next       <= ex1_q.pc + 32'd4;
      reg_q.branch_taken  <= 1'b0;
      reg_q.branch_target <= 32'b0;
      reg_q.ctrl          <= ex1_q.ctrl;
      reg_q.instr         <= ex1_q.instr;
      reg_q.valid         <= ex1_q.valid;
    end else if (iter_div_op) begin
      // The DIV/REM instruction is still occupying EX2. Clear EX/MEM so
      // older instructions can drain and no stale instruction re-retires.
      reg_q <= '0;
    end else begin
      reg_q.pc            <= ex1_q.pc;
      // For JAL/JALR, rd_wdata is PC+4 (return address), not the target.
      reg_q.alu_result    <= ex1_q.ctrl.is_jump ? (ex1_q.pc + 32'd4) : alu_result;
      reg_q.write_data    <= ex1_q.rs2_val;
      reg_q.rd            <= ex1_q.rd;
      reg_q.rs1_addr      <= ex1_q.rs1_addr;
      reg_q.rs2_addr      <= ex1_q.rs2_addr;
      reg_q.rs1_val       <= ex1_q.rs1_val;
      reg_q.rs2_val       <= ex1_q.rs2_val;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // stays consistent with the suppressed redirect.
      reg_q.pc_next       <= misalign_fault        ? (ex1_q.pc + 32'd4)
                            : ex1_q.ctrl.is_jump   ? ex1_q.jump_target
                            : branch_taken         ? ex1_q.branch_target
                                                   : (ex1_q.pc + 32'd4);
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= ex1_q.branch_target;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= ex1_q.instr;
      reg_q.valid         <= ex1_q.valid;
    end
  end

  // ── EX1/EX2 register ──────────────────────────────────────────────────
  assign hold_ex1 = stall || div_stall;

  always_ff @(posedge clock) begin
    if (reset) begin
      ex1_q <= '0;
    end else if (hold_ex1) begin
      ex1_q <= ex1_q;
    end else if (flush_ex1 || bubble_ex1) begin
      ex1_q <= '0;
    end else begin
      ex1_q <= ex1_next;
    end
  end

  assign out           = reg_q;
  assign ex1_rd        = ex1_q.rd;
  assign ex1_reg_write = ex1_q.valid && ctrl_with_trap.reg_write;
  assign ex1_mem_read  = ex1_q.valid && ex1_q.ctrl.mem_read;

endmodule
