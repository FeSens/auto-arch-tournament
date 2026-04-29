// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, and redirects only when the
// IF-stage outcome prediction needs repair. Owns the EX/MEM pipeline register.
//
// Forwarding select encoding (driven by forward_unit):
//   00 = ID/EX register value (no forward)
//   01 = EX/MEM aluResult (instruction immediately ahead in MEM)
//   10 = MEM/WB result (instruction two ahead, post regfile-write mux)
//
// Latency:        1 cycle (EX/MEM register clocked here).
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
  output logic               ex_long_busy,
  output logic               redirect,
  output logic [31:0]        redirect_target
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
  alu u_alu (
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result)
  );

  // ── Cold divide/remainder unit ────────────────────────────────────────
  logic is_div_op;
  logic div_request;
  logic div_start;
  logic div_busy;
  logic div_done;
  logic [31:0] div_result_w;
  logic        div_active_q;
  logic        div_result_valid_q;
  logic [31:0] div_result_q;
  /* verilator lint_off UNUSEDSIGNAL */
  id_ex_t      div_in_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] div_rs1_q;
  logic [31:0] div_rs2_q;
  logic        div_complete;
  logic [31:0] div_result_selected;

  always_comb begin
    is_div_op   = (in.ctrl.alu_op == ALU_DIV)
               || (in.ctrl.alu_op == ALU_DIVU)
               || (in.ctrl.alu_op == ALU_REM)
               || (in.ctrl.alu_op == ALU_REMU);
    div_request = in.valid && is_div_op && !in.ctrl.is_illegal && !div_active_q;
    div_start   = div_request && !stall;
    div_complete = div_active_q && (div_result_valid_q || div_done);
    div_result_selected = div_result_valid_q ? div_result_q : div_result_w;
    // Asserted on the launch cycle and every busy cycle. It deasserts on the
    // completion cycle so IF/ID can advance while the completed DIV enters
    // EX/MEM.
    ex_long_busy = div_start || div_busy || (div_active_q && !div_complete);
  end

  div_unit u_div (
    .clock  (clock),
    .reset  (reset),
    .start  (div_start),
    .op     (in.ctrl.alu_op),
    .a      (alu_a),
    .b      (alu_b),
    .busy   (div_busy),
    .done   (div_done),
    .result (div_result_w)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] branch_next_pc;
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
    branch_next_pc = branch_taken ? branch_target : (in.pc + 32'd4);
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
  logic branch_mispredict;
  logic jump_redirect;
  logic jal_mispredict;
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

    branch_mispredict = in.valid
                     && in.ctrl.is_branch
                     && !misalign_fault
                     && (branch_taken != in.predicted_taken);
    jal_mispredict    = in.ctrl.is_jump
                     && !in.ctrl.is_jalr
                     && !in.predicted_taken;
    jump_redirect     = in.valid
                     && in.ctrl.is_jump
                     && !misalign_fault
                     && (in.ctrl.is_jalr || jal_mispredict);
  end

  assign redirect        = branch_mispredict || jump_redirect;
  assign redirect_target = in.ctrl.is_jump ? jump_target : branch_next_pc;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      div_active_q       <= 1'b0;
      div_result_valid_q <= 1'b0;
      div_result_q       <= 32'b0;
      div_in_q           <= '0;
      div_rs1_q          <= 32'b0;
      div_rs2_q          <= 32'b0;
    end else begin
      if (div_start) begin
        div_active_q       <= 1'b1;
        div_result_valid_q <= 1'b0;
        div_result_q       <= 32'b0;
        div_in_q           <= in;
        div_rs1_q          <= rs1;
        div_rs2_q          <= rs2;
      end else if (div_complete && !stall) begin
        div_active_q       <= 1'b0;
        div_result_valid_q <= 1'b0;
      end else if (div_done && div_active_q) begin
        div_result_q       <= div_result_w;
        div_result_valid_q <= 1'b1;
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (div_complete) begin
      reg_q.pc            <= div_in_q.pc;
      reg_q.alu_result    <= div_result_selected;
      reg_q.write_data    <= div_rs2_q;
      reg_q.rd            <= div_in_q.rd;
      reg_q.rs1_addr      <= div_in_q.rs1_addr;
      reg_q.rs2_addr      <= div_in_q.rs2_addr;
      reg_q.rs1_val       <= div_rs1_q;
      reg_q.rs2_val       <= div_rs2_q;
      reg_q.pc_next       <= div_in_q.pc + 32'd4;
      reg_q.branch_taken  <= 1'b0;
      reg_q.branch_target <= div_in_q.pc + div_in_q.imm;
      reg_q.ctrl          <= div_in_q.ctrl;
      reg_q.instr         <= div_in_q.instr;
      reg_q.valid         <= div_in_q.valid;
    end else if (div_start || div_active_q) begin
      // A divide-class instruction occupies EX until completion. EX/MEM gets
      // bubbles while the unit is busy so older instructions are not replayed.
      reg_q <= '0;
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
