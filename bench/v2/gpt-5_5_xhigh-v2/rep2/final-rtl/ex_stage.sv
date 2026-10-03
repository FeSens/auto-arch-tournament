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
  output logic               busy,
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

  // Loads/stores always use rs1+imm. Keep this address out of the generic
  // ALU result mux so MEM timing does not depend on shift/compare/jump cases.
  logic [31:0] mem_addr_fast;
  assign mem_addr_fast = rs1 + in.imm;

  // ── Sequential RV32M unit ─────────────────────────────────────────────
  logic        is_m_op;
  logic        muldiv_start;
  logic        muldiv_busy;
  logic        muldiv_done;
  logic [31:0] muldiv_result;

  assign is_m_op = in.valid && !in.ctrl.is_illegal &&
                   ((in.ctrl.alu_op == ALU_MUL)    ||
                    (in.ctrl.alu_op == ALU_MULH)   ||
                    (in.ctrl.alu_op == ALU_MULHU)  ||
                    (in.ctrl.alu_op == ALU_MULHSU) ||
                    (in.ctrl.alu_op == ALU_DIV)    ||
                    (in.ctrl.alu_op == ALU_DIVU)   ||
                    (in.ctrl.alu_op == ALU_REM)    ||
                    (in.ctrl.alu_op == ALU_REMU));

  muldiv_unit u_muldiv (
    .clock  (clock),
    .reset  (reset),
    .start  (muldiv_start),
    .op     (in.ctrl.alu_op),
    .a      (rs1),
    .b      (rs2),
    .busy   (muldiv_busy),
    .done   (muldiv_done),
    .result (muldiv_result)
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
  logic direct_jal_aligned;
  ctrl_t ctrl_with_trap;

  always_comb begin
    misalign_branch = in.ctrl.is_branch && branch_taken
                      && (branch_target[1:0] != 2'b00);
    misalign_jump   = in.ctrl.is_jump && (jump_target[1:0] != 2'b00);
    misalign_fault  = misalign_branch || misalign_jump;
    direct_jal_aligned = in.valid && in.ctrl.is_jump && !in.ctrl.is_jalr
                         && !misalign_jump;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  assign redirect        = !busy && !stall && in.valid &&
                           (branch_taken ||
                            (in.ctrl.is_jump && !direct_jal_aligned)) &&
                           !misalign_fault;
  assign redirect_target = in.ctrl.is_jump ? jump_target : branch_target;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;
  ex_mem_t muldiv_payload_q;
  ex_mem_t muldiv_payload_d;
  logic    muldiv_inflight_q;

  assign muldiv_start = is_m_op && !muldiv_inflight_q && !stall;
  assign busy         = muldiv_start || muldiv_inflight_q || muldiv_busy;

  always_comb begin
    muldiv_payload_d               = '0;
    muldiv_payload_d.pc            = in.pc;
    muldiv_payload_d.alu_result    = 32'b0;
    muldiv_payload_d.mem_addr_fast = 32'b0;
    muldiv_payload_d.write_data    = rs2;
    muldiv_payload_d.rd            = in.rd;
    muldiv_payload_d.rs1_addr      = in.rs1_addr;
    muldiv_payload_d.rs2_addr      = in.rs2_addr;
    muldiv_payload_d.rs1_val       = rs1;
    muldiv_payload_d.rs2_val       = rs2;
    muldiv_payload_d.pc_next       = in.pc + 32'd4;
    muldiv_payload_d.branch_taken  = 1'b0;
    muldiv_payload_d.branch_target = 32'b0;
    muldiv_payload_d.ctrl          = in.ctrl;
    muldiv_payload_d.instr         = in.instr;
    muldiv_payload_d.valid         = in.valid;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q             <= '0;
      muldiv_payload_q  <= '0;
      muldiv_inflight_q <= 1'b0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (muldiv_done && muldiv_inflight_q) begin
      reg_q             <= muldiv_payload_q;
      reg_q.alu_result  <= muldiv_result;
      muldiv_inflight_q <= 1'b0;
    end else if (muldiv_start) begin
      // Let the older EX/MEM instruction drain into MEM/WB once, then keep
      // the boundary bubbled until the sequential result is available.
      reg_q             <= '0;
      muldiv_payload_q  <= muldiv_payload_d;
      muldiv_inflight_q <= 1'b1;
    end else if (muldiv_inflight_q) begin
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
      reg_q.mem_addr_fast <= mem_addr_fast;
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
