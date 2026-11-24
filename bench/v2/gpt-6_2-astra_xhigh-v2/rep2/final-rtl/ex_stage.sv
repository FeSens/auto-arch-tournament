// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, and issues checked memory
// requests. Owns the EX/MEM pipeline register.
//
// Forwarding select encoding (driven by forward_unit):
//   00 = ID/EX register value (no forward)
//   01 = EX/MEM result, including an accepted load
//   10 = MEM/WB result, including any M operation
//
// DIV/REM hold ID/EX for issue and six iterations. Other operations take
// one cycle when MEM can advance.
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
  input  logic [31:0]        fwd_mem_wb,
  output logic [31:0]        alu_a, alu_b,  // operands for the ID address predictor
  output logic               repair,
  output logic [31:0]        repaired_addr,
  output logic [31:0]        dmem_addr, dmem_wdata,
  input  logic [31:0]        dmem_rdata,
  output logic [3:0]         dmem_wen,
  output logic               dmem_ren,
  output ex_mem_t  out,
  output logic               div_wait,
  output logic [31:0]        div_result,    // MEM sideband from the final divider registers
  output logic               redirect,
  output logic [31:0]        redirect_target
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  // The forward unit already gives the youngest eligible producer priority.
  // Its two select bits are mutually exclusive.
  assign rs1 = ({32{fwd_rs1_sel == 2'b00}} & in.rs1_val)
             | ({32{fwd_rs1_sel[0]}} & fwd_ex_mem)
             | ({32{fwd_rs1_sel[1]}} & fwd_mem_wb);
  assign rs2 = ({32{fwd_rs2_sel == 2'b00}} & in.rs2_val)
             | ({32{fwd_rs2_sel[0]}} & fwd_ex_mem)
             | ({32{fwd_rs2_sel[1]}} & fwd_mem_wb);

  // ── ALU operand selection ─────────────────────────────────────────────
  always_comb begin
    alu_a = in.ctrl.is_auipc ? in.pc  : rs1;
    alu_b = in.ctrl.alu_src  ? in.imm : rs2;
  end

  // The request address comes directly from ID/EX. On a prediction miss,
  // hold the slot for one edge to replace that same register with rs1+imm.
  logic repaired, addr_checked, mem_op, mem_misalign;
  assign dmem_addr = in.mem_addr;
  assign mem_op = in.ctrl.mem_read || in.ctrl.mem_write;
  assign addr_checked = repaired || (in.base_available && !in.page_cross);
  assign repair = mem_op && !addr_checked;
  assign repaired_addr = rs1 + in.imm;
  always_ff @(posedge clock) begin
    if (reset || !stall) repaired <= 1'b0;
    else if (repair)     repaired <= 1'b1;
  end

  assign mem_misalign = (in.ctrl.mem_width == 2'd2 && dmem_addr[1:0] != 0)
                     || (in.ctrl.mem_width == 2'd1 && dmem_addr[0]);
  assign dmem_wen = (in.ctrl.mem_write && addr_checked && !mem_misalign)
                  ? access_mask(in.ctrl.mem_width, dmem_addr[1:0]) : 4'b0;
  assign dmem_ren = in.ctrl.mem_read && addr_checked && !mem_misalign;
  assign dmem_wdata = store_lanes(in.ctrl.mem_width, rs2);

  logic [15:0] halfword;
  logic [7:0]  lane;
  logic [31:0] load_data;
  assign halfword = dmem_addr[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];
  assign lane = dmem_addr[0] ? halfword[15:8] : halfword[7:0];
  always_comb begin
    case (in.ctrl.mem_width)
      2'd0:    load_data = {{24{in.ctrl.mem_sext && lane[7]}}, lane};
      2'd1:    load_data = {{16{in.ctrl.mem_sext && halfword[15]}}, halfword};
      default: load_data = dmem_rdata;
    endcase
  end

  logic [31:0] alu_result;
  logic        is_div, div_ready, div_valid, div_issue, div_consume;
  assign is_div = in.valid && in.ctrl.late_result && in.instr[14];
  assign div_wait    = is_div && !div_valid;
  assign div_issue   = is_div && div_ready && !stall;
  assign div_consume = is_div && div_valid && !stall;

  alu u_alu (
    .clock       (clock),
    .reset       (reset),
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result),
    .div_request (div_issue),
    .div_ready   (div_ready),
    .div_valid   (div_valid),
    .div_result  (div_result),
    .div_consume (div_consume)
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
    jalr_sum    = repaired_addr;
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
    if (misalign_fault || (mem_op && mem_misalign)) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
      ctrl_with_trap.mem_read   = 1'b0;
      ctrl_with_trap.mem_write  = 1'b0;
    end
  end

  // Check each target's alignment in parallel with the branch decision.
  assign redirect = ((branch_taken || (in.ctrl.is_jump && !in.ctrl.is_jalr))
                     && branch_target[1:0] == 2'b00)
                 || (in.ctrl.is_jalr && !jalr_sum[1]);
  assign redirect_target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0} : branch_target;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // Keep the forwarding sources for both the repair and any denied request.
      reg_q <= reg_q;
    end else begin
      reg_q.pc            <= in.pc;
      reg_q.alu_result    <= in.ctrl.mem_read ? load_data :
                             in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
      reg_q.forwardable   <= ctrl_with_trap.reg_write && !in.ctrl.late_result;
      reg_q.mem_addr      <= dmem_addr;
      reg_q.mem_rdata     <= dmem_rdata;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      // EX/MEM is empty during the wait. Save the RVFI operands here on
      // issue, before their forwarding sources drain, and hold through transfer.
      if (div_ready) begin
        reg_q.rs1_val <= rs1;
        reg_q.rs2_val <= rs2;
      end
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect.
      reg_q.pc_next       <= misalign_fault     ? (in.pc + 32'd4)
                            : in.ctrl.is_jump   ? jump_target
                            : branch_taken      ? branch_target
                                                : (in.pc + 32'd4);
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.ctrl          <= div_wait ? '0 : ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid && !div_wait;
    end
  end

  assign out = reg_q;

endmodule
