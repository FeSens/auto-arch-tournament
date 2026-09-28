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
// Latency:        1 cycle except DIV/REM (EX/MEM accepts on the eighth
//                 compute edge after launch; successive divides are 9 apart).
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
  input  logic               fwd_ex_mem_load,
  input  logic [31:0]        fwd_mem_wb,    // WB-stage write-data mux output
  output ex_mem_t  out,
  output logic [31:0]        mem_addr,      // normal bank; DIV/REM never access memory
  output logic               div_wait,     // hold ID/EX and fetch, drain MEM/WB
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
  logic [31:0] div_registered_result;
  // Live response data is available for protocol verification, but is
  // deliberately not consumed by the EX/MEM normal-result register.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] div_resp_data;
  /* verilator lint_on UNUSEDSIGNAL */
  logic is_div, div_operands_ready, div_active_q;
  logic div_req_valid, div_req_ready, div_resp_valid, div_accept;
  logic [31:0] div_rs1_q, div_rs2_q;

  assign is_div = in.valid && !in.ctrl.is_illegal &&
                  (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU ||
                   in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU);
  // Ordinary load-use interlocking normally inserts this bubble already.
  // Never launch using a load's address as a forwarded divide operand.
  assign div_operands_ready = !fwd_ex_mem_load ||
                             (fwd_rs1_sel != 2'd1 && fwd_rs2_sel != 2'd1);
  assign div_req_valid = is_div && !div_active_q && div_operands_ready && !stall && !reset;
  assign div_accept = is_div && div_active_q && div_resp_valid && !stall && !reset;
  assign div_wait = is_div && !div_accept;

  always_ff @(posedge clock) begin
    if (reset) begin
      div_active_q <= 1'b0;
    end else if (div_req_valid && div_req_ready) begin
      div_active_q <= 1'b1;
    end else if (div_accept) begin
      div_active_q <= 1'b0;
    end
  end

  // Idle snapshots follow forwarding without launch qualification. The
  // launch edge captures its exact operands before div_active_q takes
  // ownership. Hold through acceptance: EX/MEM samples these old values
  // on the edge that releases ownership, even for a blocked response.
  always_ff @(posedge clock) begin
    if (reset) begin
      div_rs1_q <= 32'b0;
      div_rs2_q <= 32'b0;
    end else if (!div_active_q) begin
      div_rs1_q <= rs1;
      div_rs2_q <= rs2;
    end
  end

  alu u_alu (
    .clock          (clock),
    .reset          (reset),
    .div_req_valid  (div_req_valid),
    .div_req_ready  (div_req_ready),
    .div_resp_valid (div_resp_valid),
    .div_resp_ready (div_accept),
    .div_resp_data  (div_resp_data),
    .div_registered_result (div_registered_result),
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

  assign redirect        = in.valid && (branch_taken || in.ctrl.is_jump) && !misalign_fault;
  assign redirect_target = in.ctrl.is_jump ? jump_target : branch_target;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;
  logic div_result_sel_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q.ctrl <= '0;
      reg_q.valid <= 1'b0;
      div_result_sel_q <= 1'b0;
    end else if (!stall) begin
      if (div_wait || !in.valid) begin
        // The older owner advances exactly once; inactive payload must
        // never retain a write, memory request, or forwarding control.
        reg_q.ctrl <= '0;
        reg_q.valid <= 1'b0;
        div_result_sel_q <= 1'b0;
      end else begin
        reg_q.ctrl <= ctrl_with_trap;
        reg_q.valid <= in.valid;
        div_result_sel_q <= div_accept;
      end
    end
  end

  // Each payload bit has one owner, independent of bubble/completion
  // control. Only a memory hold freezes these registers, including the
  // direct address bank. Reset remains synchronous and clears all data.
  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q.pc            <= 32'b0;
      reg_q.alu_result    <= 32'b0;
      reg_q.write_data    <= 32'b0;
      reg_q.rd            <= 5'b0;
      reg_q.rs1_addr      <= 5'b0;
      reg_q.rs2_addr      <= 5'b0;
      reg_q.rs1_val       <= 32'b0;
      reg_q.rs2_val       <= 32'b0;
      reg_q.pc_next       <= 32'b0;
      reg_q.branch_taken  <= 1'b0;
      reg_q.branch_target <= 32'b0;
      reg_q.instr         <= 32'b0;
    end else if (!stall) begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      // On div_accept, result_q in u_div captures the terminal result
      // on this same edge (or already holds it). The registered selector
      // makes that bank authoritative; this normal capture is inactive.
      reg_q.alu_result    <= in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
      reg_q.write_data    <= is_div ? div_rs2_q : rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= is_div ? div_rs1_q : rs1;
      reg_q.rs2_val       <= is_div ? div_rs2_q : rs2;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect.
      reg_q.pc_next       <= misalign_fault     ? (in.pc + 32'd4)
                            : in.ctrl.is_jump   ? jump_target
                            : branch_taken      ? branch_target
                                                : (in.pc + 32'd4);
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.instr         <= in.instr;
    end
  end

  // Both forwarding and MEM/WB consume this selection of registered
  // banks. No live opcode, response-valid, or arithmetic feeds the mux.
  // Blocking issue protects ownership: after accept, no younger request
  // can launch until an unstalled edge that also advances this owner.
  // A hold suppresses requests, and a launch cannot modify result_q;
  // the next completion is another eight compute edges later.
  always_comb begin
    out = reg_q;
    out.alu_result = div_result_sel_q ? div_registered_result : reg_q.alu_result;
  end
  // Keep the memory address directly registered. Routing the bank mux
  // here would prevent the FPGA wrapper's memory from absorbing its
  // address register into block RAM. Only normal instructions access
  // memory, so the divider bank is never an address owner.
  assign mem_addr = reg_q.alu_result;

endmodule
