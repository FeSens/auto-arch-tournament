// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// Forwarding select encoding (registered in ID, with hold maintenance):
//   00 = ID/EX register value (no forward)
//   01 = EX/MEM aluResult (instruction immediately ahead in MEM)
//   10 = MEM/WB result (instruction two ahead, post regfile-write mux)
//
// Latency: ordinary EX takes one edge; M execution owns EX through accept.
// MUL uses launch/reduce/accept; DIV uses raw launch/PREP/six LOOP edges/accept.
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
  // Destination and scalar-write eligibility of the token enqueued on
  // this edge, for decode lookahead. Loads are never scalar producers.
  output logic [4:0]          producer_rd,
  output logic               producer_w_en,
  output logic               hold_frontend,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               train_valid,
  output logic [31:0]        train_pc,
  output logic               train_taken
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

  // Complete memory requests have their own datapath and register lane.
  // Use raw forwarded operands: neither AUIPC/ALU operand selection nor
  // scalar result arbitration participates in the effective address.
  logic [31:0] mem_addr, mem_wdata;
  logic [3:0] mem_mask, mem_rmask, mem_wmask;
  logic mem_op, mem_misalign, width_misalign;

  assign mem_addr = rs1 + in.imm;
  always_comb begin
    mem_mask = 4'b0000;
    mem_wdata = rs2;
    width_misalign = 1'b0;
    case (in.ctrl.mem_width)
      2'd0: begin
        mem_mask = 4'b0001 << mem_addr[1:0];
        mem_wdata = {4{rs2[7:0]}};
      end
      2'd1: begin
        mem_mask = 4'b0011 << mem_addr[1:0];
        mem_wdata = {2{rs2[15:0]}};
        width_misalign = mem_addr[0];
      end
      2'd2: begin
        mem_mask = 4'b1111;
        width_misalign = |mem_addr[1:0];
      end
      default: ; // No request for an unvalidated width.
    endcase
    mem_op = in.valid && !in.ctrl.is_illegal &&
             (in.ctrl.mem_read || in.ctrl.mem_write);
    mem_misalign = mem_op && width_misalign;
    mem_rmask = (mem_op && in.ctrl.mem_read && !width_misalign)
                ? mem_mask : 4'b0000;
    mem_wmask = (mem_op && in.ctrl.mem_write && !width_misalign)
                ? mem_mask : 4'b0000;
  end

  logic is_m, m_start, m_busy, m_done, m_accept, m_load_dependency;
  logic [31:0] m_result;
  ex_mem_t m_metadata_q;

  assign is_m = in.valid && !in.ctrl.is_illegal &&
                (in.ctrl.alu_op == ALU_MUL || in.ctrl.alu_op == ALU_MULH ||
                 in.ctrl.alu_op == ALU_MULHU || in.ctrl.alu_op == ALU_MULHSU ||
                 in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU ||
                 in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU);
  // An independent older memory request may stay stalled while M execution
  // runs. Never capture an older LOAD's address as a forwarded operand;
  // wait for that producer to reach WB before accepting the request.
  assign m_load_dependency = out.valid && out.ctrl.mem_read && out.rd != 5'b0
                              && (out.rd == in.rs1_addr || out.rd == in.rs2_addr);
  assign m_start = is_m && !m_busy && !m_load_dependency && !reset;
  assign m_accept = m_done && !stall;
  // Hold the current ID/EX instruction from launch through completion.
  // On the enqueue edge, ID can capture the next instruction immediately.
  assign hold_frontend = (is_m || m_busy) && !m_accept;

  m_unit u_m (
    .clock(clock), .reset(reset), .start(m_start), .accept(m_accept),
    .op(in.ctrl.alu_op), .a(rs1), .b(rs2),
    .busy(m_busy), .done(m_done), .result(m_result)
  );

  always_ff @(posedge clock) begin
    if (reset) m_metadata_q <= '0;
    else if (m_start) begin
      m_metadata_q.pc <= in.pc;
      m_metadata_q.alu_result <= 32'b0;
      m_metadata_q.write_data <= rs2;
      m_metadata_q.mem_addr <= 32'b0;
      m_metadata_q.mem_wdata <= 32'b0;
      m_metadata_q.mem_rmask <= 4'b0;
      m_metadata_q.mem_wmask <= 4'b0;
      m_metadata_q.mem_misalign <= 1'b0;
      m_metadata_q.rd <= in.rd;
      m_metadata_q.rs1_addr <= in.rs1_addr;
      m_metadata_q.rs2_addr <= in.rs2_addr;
      m_metadata_q.rs1_val <= rs1;
      m_metadata_q.rs2_val <= rs2;
      m_metadata_q.pc_next <= in.sequential_pc;
      m_metadata_q.branch_taken <= 1'b0;
      m_metadata_q.branch_target <= 32'b0;
      m_metadata_q.ctrl <= in.ctrl;
      m_metadata_q.instr <= in.instr;
      m_metadata_q.valid <= 1'b1;
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

  // Recovery consumes the registered decode predicates directly. The late
  // forwarded comparison does not traverse branch-op selection, transfer
  // arbitration, trap selection or prediction XOR on its way to fetch.
  logic branch_recovery;
  assign branch_recovery =
      (in.recover_eq  && (rs1 == rs2)) |
      (in.recover_ne  && (rs1 != rs2)) |
      (in.recover_lt  && ($signed(rs1) <  $signed(rs2))) |
      (in.recover_ge  && ($signed(rs1) >= $signed(rs2))) |
      (in.recover_ltu && (rs1 <  rs2)) |
      (in.recover_geu && (rs1 >= rs2));
  assign redirect = in.valid && !reset && !stall && !m_busy
                    && (branch_recovery || in.recover_jal ||
                        (in.recover_jalr && !jalr_sum[1]));
  // A conditional mismatch reverses the accepted direction. Direct JAL
  // only recovers from sequential prediction; JALR clears bit zero.
  // Thus address selection is independent of the operand comparison.
  assign redirect_target = in.recover_jalr ? {jalr_sum[31:1], 1'b0}
                           : in.predicted_taken ? in.sequential_pc
                                                : in.direct_target;
  assign train_valid = in.valid && !reset && !stall && !m_busy
                       && in.ctrl.is_branch && !in.ctrl.is_illegal && !misalign_fault;
  assign train_pc = in.pc;
  assign train_taken = branch_taken;

  always_comb begin
    producer_rd = m_accept ? m_metadata_q.rd : in.rd;
    producer_w_en = 1'b0;
    if (!reset && !stall) begin
      if (m_accept)
        producer_w_en = m_metadata_q.valid && m_metadata_q.ctrl.reg_write
                        && !m_metadata_q.ctrl.is_illegal && producer_rd != 5'b0;
      else if (!is_m && !m_busy)
        producer_w_en = in.valid && ctrl_with_trap.reg_write
                        && !ctrl_with_trap.is_illegal && !mem_misalign
                        && !in.ctrl.mem_read && producer_rd != 5'b0;
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
    end else if (m_accept) begin
      reg_q <= m_metadata_q;
      reg_q.alu_result <= m_result;
    end else if (is_m || m_busy) begin
      // MEM has accepted the previous entry; drain it exactly once and
      // emit bubbles while the M unit owns EX. A data stall above keeps
      // the older request and every bus output stable instead.
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= in.ctrl.is_jump ? in.sequential_pc : alu_result;
      reg_q.write_data    <= rs2;
      reg_q.mem_addr      <= mem_addr;
      reg_q.mem_wdata     <= mem_wdata;
      reg_q.mem_rmask     <= mem_rmask;
      reg_q.mem_wmask     <= mem_wmask;
      reg_q.mem_misalign  <= mem_misalign;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= rs1;
      reg_q.rs2_val       <= rs2;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect.
      reg_q.pc_next       <= misalign_fault     ? in.sequential_pc
                            : in.ctrl.is_jump   ? jump_target
                            : branch_taken      ? branch_target
                                                : in.sequential_pc;
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
