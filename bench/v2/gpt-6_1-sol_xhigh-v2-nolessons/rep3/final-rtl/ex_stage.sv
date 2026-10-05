// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// Forwarding selects are registered with the consumer at ID/EX capture:
//   00 = ID/EX register value (no forward)
//   01 = EX/MEM aluResult (instruction immediately ahead in MEM)
//   10 = MEM/WB result (instruction two ahead, post regfile-write mux)
//
// Latency:        integer 1 cycle; all M operations hold EX until completion.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  input  logic [1:0]         fwd_rs1_sel,
  input  logic [1:0]         fwd_rs2_sel,
  // One-hot choices: bit 0 = ID/EX, 1 = EX/MEM, 2 = WB,
  // bit 3 = PC for A, immediate for B. No serial source-override mux.
  input  logic [3:0]         alu_a_sel,
  input  logic [3:0]         alu_b_sel,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // WB-stage write-data mux output
  output ex_mem_t  out,
  output logic               next_reg_write,
  output logic               divide_wait,
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
    alu_a = ({32{alu_a_sel[0]}} & in.rs1_val)
          | ({32{alu_a_sel[1]}} & fwd_ex_mem)
          | ({32{alu_a_sel[2]}} & fwd_mem_wb)
          | ({32{alu_a_sel[3]}} & in.pc);
    alu_b = ({32{alu_b_sel[0]}} & in.rs2_val)
          | ({32{alu_b_sel[1]}} & fwd_ex_mem)
          | ({32{alu_b_sel[2]}} & fwd_mem_wb)
          | ({32{alu_b_sel[3]}} & in.imm);
  end

  logic [31:0] alu_result;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] m_result;
  /* verilator lint_on UNUSEDSIGNAL */
  // These ownership names cover both the multiplier and the divider.
  logic is_divide, divide_active_q;
  logic div_req_valid, div_req_ready, div_result_valid, div_result_ready;
  logic divide_launch;
  logic recovery_valid_q;
  ex_mem_t divide_snapshot_q;

`ifdef RISCV_FORMAL_ALTOPS
  // Preserve the bounded formal model's exact single-cycle ALTOPS behavior.
  assign is_divide = 1'b0;
`else
  assign is_divide = in.valid && !recovery_valid_q &&
                     (in.is_multiply || in.is_divide);
`endif
  assign div_req_valid = is_divide && !divide_active_q && !stall;
  assign divide_launch = div_req_valid && div_req_ready;
  assign div_result_ready = divide_active_q && !stall;
  // The launch cycle holds ID/EX too. Only a result transfer releases it.
  assign divide_wait = !recovery_valid_q && (is_divide || divide_active_q) &&
                       !(divide_active_q && div_result_valid && !stall);

  alu #(.SEPARATE_M(1'b1), .PREDECODED_RESULT(1'b1)) u_alu (
    .clock (clock),
    .reset (reset),
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .div_req_valid    (div_req_valid),
    .div_req_ready    (div_req_ready),
    .div_result_valid (div_result_valid),
    .div_result_ready (div_result_ready),
    .m_is_multiply   (in.is_multiply),
    .m_is_divide     (in.is_divide),
    .result_grants   (in.result_grants),
    .pc_plus4        (in.pc + 32'd4),
    .m_complete      (divide_active_q && div_result_valid),
    .m_result        (m_result),
    .out (alu_result)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_mismatch;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] jump_target;
  logic [31:0] branch_imm, jump_imm;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] jalr_sum;  // bit 0 deliberately dropped per RV JALR spec
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    case (in.mismatch_op)
      BR_BEQ:  branch_mismatch = (rs1 == rs2);
      BR_BNE:  branch_mismatch = (rs1 != rs2);
      BR_BLT:  branch_mismatch = ($signed(rs1) <  $signed(rs2));
      BR_BGE:  branch_mismatch = ($signed(rs1) >= $signed(rs2));
      BR_BLTU: branch_mismatch = (rs1 <  rs2);
      BR_BGEU: branch_mismatch = (rs1 >= rs2);
      default: branch_mismatch = 1'b0;
    endcase
    branch_taken = in.ctrl.is_branch && (branch_mismatch ^ in.predicted_taken);
    // The original direct immediates remain in the retained instruction;
    // ID/EX imm is the recovery payload only for validated B/J instructions.
    branch_imm = {{19{in.instr[31]}}, in.instr[31], in.instr[7],
                  in.instr[30:25], in.instr[11:8], 1'b0};
    jump_imm = {{11{in.instr[31]}}, in.instr[31], in.instr[19:12],
                in.instr[20], in.instr[30:21], 1'b0};
    branch_target = in.pc + branch_imm;
    // JALR clears bit 0 (RV spec); JAL uses imm directly.
    jalr_sum    = rs1 + in.imm;
    jump_target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0}
                                  : (in.pc + jump_imm);
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
                      && !in.direct_aligned;
    misalign_jump   = in.ctrl.is_jump && (in.ctrl.is_jalr
                     ? jump_target[1:0] != 2'b00 : !in.direct_aligned);
    misalign_fault  = misalign_branch || misalign_jump;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
    end
    // Conditional branches have no destination. Their operand comparator
    // affects trapping and redirect, but only jump alignment gates writers.
    ctrl_with_trap.reg_write = in.ctrl.reg_write && !misalign_jump;
  end

  assign redirect = recovery_valid_q;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;
  ex_mem_t normal_result;
  logic [31:0] effective_addr_q, store_data_q;
  logic [31:0] arithmetic_result_q;
  // Consume the resolving instruction's pre-edge registered lane before
  // ordinary capture overwrites it. No separate target register is needed.
  assign redirect_target = reg_q.ctrl.is_jalr
                         ? {effective_addr_q[31:1], 1'b0} : arithmetic_result_q;

  always_comb begin
    normal_result = '0;
    normal_result.pc            = in.pc;
    normal_result.rd            = in.rd;
    normal_result.rs1_addr      = in.rs1_addr;
    normal_result.rs2_addr      = in.rs2_addr;
    normal_result.rs1_val       = rs1;
    normal_result.rs2_val       = rs2;
    normal_result.pc_next       = misalign_fault   ? (in.pc + 32'd4)
                               : in.ctrl.is_jump ? jump_target
                               : branch_taken    ? branch_target
                                                 : (in.pc + 32'd4);
    normal_result.branch_taken  = branch_taken;
    normal_result.branch_target = branch_target;
    normal_result.ctrl          = ctrl_with_trap;
    // Validity is authoritative at the registered producer/request boundary.
    normal_result.ctrl.reg_write = ctrl_with_trap.reg_write && in.valid && !recovery_valid_q;
    normal_result.ctrl.mem_read  = ctrl_with_trap.mem_read && in.valid && !recovery_valid_q;
    normal_result.ctrl.mem_write = ctrl_with_trap.mem_write && in.valid && !recovery_valid_q;
    normal_result.instr         = in.instr;
    normal_result.valid         = in.valid && !recovery_valid_q;
  end

  // Predict the producer entering EX/MEM on the consumer's capture edge.
  // ID/EX retains the M instruction's destination throughout ownership;
  // its saved post-trap bundle is the producer only on result completion.
  // During a memory hold decode also holds, so no new selection captures.
  assign next_reg_write = !stall && (divide_active_q
                        ? (div_result_valid && divide_snapshot_q.ctrl.reg_write)
                        : (!is_divide && normal_result.ctrl.reg_write));

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
      effective_addr_q <= '0;
      store_data_q <= '0;
      arithmetic_result_q <= '0;
      divide_active_q <= 1'b0;
      divide_snapshot_q <= '0;
      recovery_valid_q <= 1'b0;
    end else begin
      if (divide_launch) begin
        divide_active_q <= 1'b1;
        // Both arithmetic and RVFI use the forwarded values at acceptance.
        divide_snapshot_q <= normal_result;
      end
      if (div_result_valid && div_result_ready) divide_active_q <= 1'b0;

      // Memory backpressure has priority: retain an outstanding request.
      // Arithmetic and metadata insert inert bubbles while M owns EX.
      // Request payloads have their own capture enable and bypass this mux.
      if (!stall) begin
        // Only valid normal advancement can own a recovery event. An older
        // memory hold defers capture; pending recovery consumes it once.
        recovery_valid_q <= !recovery_valid_q && !divide_active_q && !is_divide &&
                            in.valid && !in.ctrl.is_illegal &&
                            ((in.ctrl.is_branch && branch_mismatch && in.direct_aligned) ||
                             (in.ctrl.is_jalr && !misalign_jump));
        if (divide_active_q) begin
          if (div_result_valid) begin
            reg_q <= divide_snapshot_q;
          end else reg_q <= '0;
        end else if (is_divide) reg_q <= '0;
        else reg_q <= normal_result;
        // Capture actual architectural forwarding, including on launch,
        // busy and completion edges. Saved M metadata never owns these.
        effective_addr_q <= rs1 + in.imm;
        store_data_q <= rs2;
        // Complete integer/link/M selection is parallel inside the ALU;
        // capture this lane on every ordinary edge, independent of metadata.
        arithmetic_result_q <= alu_result;
      end
    end
  end

  always_comb begin
    out = reg_q;
    out.effective_addr = effective_addr_q;
    out.write_data = store_data_q;
    out.alu_result = arithmetic_result_q;
  end

endmodule
