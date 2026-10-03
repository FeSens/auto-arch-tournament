// rtl/ex_stage.sv
//
// Execute stage. Uses the forwarding plan registered in ID/EX to resolve the
// operand muxes, runs the ALU, resolves branches, computes the redirect
// target, and owns the EX/MEM pipeline register. LOAD/STORE effective
// addresses are latched from the ALU's add carry chain before the broad
// operation-result mux so MEM's address path is independent of shifts,
// compares, jumps, and MUL result fan-in.
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
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // WB-stage write-data mux output
  output ex_mem_t  out,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               div_busy
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  always_comb begin
    case (in.fwd_rs1_sel)
      FWD_EX_MEM: rs1 = fwd_ex_mem;
      FWD_MEM_WB: rs1 = fwd_mem_wb;
      default: rs1 = in.rs1_val;
    endcase
    case (in.fwd_rs2_sel)
      FWD_EX_MEM: rs2 = fwd_ex_mem;
      FWD_MEM_WB: rs2 = fwd_mem_wb;
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

  logic [31:0] alu_add_result;
  logic [31:0] alu_result;
  alu u_alu (
    .op         (in.ctrl.alu_op),
    .a          (alu_a),
    .b          (alu_b),
    .add_result (alu_add_result),
    .out        (alu_result)
  );

  logic        mem_op;
  logic [31:0] ex_result;
  logic [31:0] ex_alu_result;

  assign mem_op        = in.ctrl.mem_read || in.ctrl.mem_write;
  assign ex_alu_result = in.ctrl.is_jump ? (in.pc + 32'd4)
                       : mem_op          ? alu_add_result
                                         : ex_result;

`ifdef RISCV_FORMAL_ALTOPS
  assign ex_result = alu_result;
  assign div_busy  = 1'b0;
`else
  // Real DIV/REM-class operations are kept out of the combinational ALU
  // and run through the iterative divider below.
  logic        is_div_op;
  logic        div_unit_busy;
  logic        div_done;
  logic        div_start;
  logic        div_clear;
  logic [31:0] div_result;
  logic [31:0] div_rs1_q;
  logic [31:0] div_rs2_q;
  logic [31:0] ex_rs1_val;
  logic [31:0] ex_rs2_val;

  always_comb begin
    case (in.ctrl.alu_op)
      ALU_DIV,
      ALU_DIVU,
      ALU_REM,
      ALU_REMU: is_div_op = 1'b1;
      default:  is_div_op = 1'b0;
    endcase
  end

  assign div_start = in.valid && is_div_op && !div_unit_busy && !div_done;
  assign div_clear = in.valid && is_div_op &&  div_done && !stall;
  assign div_busy  = in.valid && is_div_op && !div_done;
  assign ex_result = is_div_op ? div_result : alu_result;
  assign ex_rs1_val = is_div_op ? div_rs1_q : rs1;
  assign ex_rs2_val = is_div_op ? div_rs2_q : rs2;

  div_unit u_div (
    .clock    (clock),
    .reset    (reset),
    .start    (div_start),
    .clear    (div_clear),
    .op       (in.ctrl.alu_op),
    .dividend (alu_a),
    .divisor  (alu_b),
    .busy     (div_unit_busy),
    .done     (div_done),
    .result   (div_result)
  );

  always_ff @(posedge clock) begin
    if (reset) begin
      div_rs1_q <= 32'b0;
      div_rs2_q <= 32'b0;
    end else if (div_start) begin
      div_rs1_q <= rs1;
      div_rs2_q <= rs2;
    end
  end
`endif

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] ex_rs1_val;
  logic [31:0] ex_rs2_val;

  assign ex_rs1_val = rs1;
  assign ex_rs2_val = rs2;
`endif

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
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
`ifndef RISCV_FORMAL_ALTOPS
    end else if (in.valid && is_div_op && !div_done) begin
      // Divider busy: keep the DIV/REM instruction in ID/EX via the hazard
      // unit and let MEM/WB drain. EX/MEM carries bubbles until result handoff.
      reg_q <= '0;
`endif
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= ex_alu_result;
      reg_q.mem_addr      <= mem_op ? alu_add_result : 32'b0;
      reg_q.write_data    <= ex_rs2_val;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= ex_rs1_val;
      reg_q.rs2_val       <= ex_rs2_val;
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
