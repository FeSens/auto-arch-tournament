// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// A load consumer uses the synchronous table output while MEM verifies
// its address and format. A failed verification kills this execution at the edge.
//
// Latency:        1 cycle for fast ops. DIV/REM hold ID/EX until completion.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  logic               replay,        // keep ID/EX and bubble EX/MEM on release
  input  id_ex_t   in,
  input  bypass_t            fwd_rs1_sel,
  input  bypass_t            fwd_rs2_sel,
  input  bypass_t            alu_b_sel,
  input  logic [31:0]        predicted_value,
  input  logic               rs1_trace_load,
  input  logic               rs2_trace_load,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // WB-stage write-data mux output
  output ex_mem_t  out,
  output logic [7:0]         lookup_index,
  output logic               div_wait,
  output logic               will_write,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               fence_i,
  output logic               train_en,
  output logic [6:0]         train_index,
  output logic [1:0]         train_counter
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  function automatic logic [31:0] operand(input bypass_t sel, input logic [31:0] captured);
    operand = ({32{sel.captured}} & captured)
            | ({32{sel.mem_wb}}   & fwd_mem_wb)
            | ({32{sel.ex_mem}}   & fwd_ex_mem)
            | ({32{sel.load}}     & predicted_value);
  endfunction

  assign rs1 = operand(fwd_rs1_sel, in.rs1_val);
  assign rs2 = operand(fwd_rs2_sel, in.rs2_val);

  // Two short adders drive the synchronous read port. MEM checks any
  // discarded carries against the separately registered full address.
  assign lookup_index[7:3] = rs1[9:5] + in.imm[9:5];
  assign lookup_index[2:0] = rs1[4:2] + in.imm[4:2];

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_b;
  assign alu_b = operand(alu_b_sel, in.rs2_val) | ({32{in.ctrl.alu_src}} & in.imm);

  logic        div_req_valid, div_req_ready, div_resp_valid, div_transfer, ex_enable;
  logic        div_negate;
  logic [31:0] unused_div_magnitude, unused_div_result, div_rs1_q, div_rs2_q;
  div_completion_t div_completion;
  logic [31:0] alu_result;

  // In an M-extension instruction, funct3[2] distinguishes DIV/REM.
  assign div_wait = in.valid && in.wb_only && in.instr[14] && !div_resp_valid;
  assign ex_enable = !stall && !replay;
  assign div_req_valid = div_wait && ex_enable;
  assign div_transfer = div_resp_valid && ex_enable;

  // Forwarding sources can drain while ID/EX holds the divide metadata.
  always_ff @(posedge clock) begin
    if (div_req_valid && div_req_ready) begin
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
    .div_resp_ready (ex_enable),
    .div_result     (unused_div_result),
    .div_magnitude  (unused_div_magnitude),
    .div_completion (div_completion),
    .div_negate     (div_negate),
    .op  (in.ctrl.alu_op),
    .a   (rs1),
    .b   (alu_b),
    .out (alu_result)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        taken;
  logic [31:0] target_sum, transfer_target, fallthrough_pc;
  logic        aligned_taken, misalign_fault;

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
  end

  assign taken = in.ctrl.is_jump || (in.ctrl.is_branch && branch_cond);
  assign target_sum = (in.ctrl.is_jalr ? rs1 : in.pc) + in.imm;
  assign transfer_target = {target_sum[31:1], target_sum[0] && !in.ctrl.is_jalr};

  // ── Misaligned branch / jump target trap ──────────────────────────────
  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, suppress the redirect (PC stays linear), and clear
  // reg_write so JAL/JALR don't write the return address on trap.
  ctrl_t ctrl_with_trap;

  assign fallthrough_pc = in.pc + 32'd4;
  assign aligned_taken  = taken && transfer_target[1:0] == 2'b00;
  assign misalign_fault = taken && transfer_target[1:0] != 2'b00;
  assign will_write     = in.valid && ctrl_with_trap.reg_write;

  always_comb begin
    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  // A taken prediction recovers to PC+4 on a mismatch. ID sets the same
  // recovery bit for FENCE.I, which always resolves sequentially and
  // therefore forces a squash and refetch at PC+4 when EX advances.
  assign fence_i         = in.valid && ex_enable && in.is_fence_i;
  assign redirect        = in.valid && ex_enable && (in.recover_fallthrough ^ aligned_taken);
  assign redirect_target = in.recover_fallthrough ? fallthrough_pc : transfer_target;

  assign train_en    = !reset && in.valid && in.ctrl.is_branch && ex_enable;
  assign train_index = in.pc[8:2];
  always_comb begin
    if (aligned_taken)
      train_counter = in.direction_counter == 2'b11 ? 2'b11 : in.direction_counter + 2'd1;
    else
      train_counter = in.direction_counter == 2'b00 ? 2'b00 : in.direction_counter - 2'd1;
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
    end else begin
      reg_q.pc            <= in.pc;
      reg_q.effective_addr <= rs1 + in.imm;
      // Only single-cycle results drive the EX-to-EX bypass.
      reg_q.alu_result    <= ({32{in.ctrl.is_jump}} & fallthrough_pc)
                           | ({32{in.ctrl.is_auipc}} & target_sum)
                           | alu_result;
      reg_q.div_valid     <= div_transfer;
      reg_q.div_negate    <= div_transfer && div_negate;
      // The multiplier takes the forwarded operand directly. Only RVFI
      // needs the divide operands saved at the request handshake.
      reg_q.mul_rs1       <= rs1;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= div_transfer ? div_rs1_q : rs1;
      reg_q.rs2_val       <= div_transfer ? div_rs2_q : rs2;
      reg_q.rs1_trace_load <= rs1_trace_load;
      reg_q.rs2_trace_load <= rs2_trace_load;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect.
      reg_q.pc_next       <= aligned_taken ? transfer_target : fallthrough_pc;
      // Let older work leave MEM, then put bubbles behind it until transfer.
      reg_q.ctrl          <= (div_wait || replay || !in.valid) ? '0 : ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid && !div_wait && !replay;
    end
  end

  always_comb begin
    out = reg_q;
    out.div_completion = div_completion;
  end

endmodule
