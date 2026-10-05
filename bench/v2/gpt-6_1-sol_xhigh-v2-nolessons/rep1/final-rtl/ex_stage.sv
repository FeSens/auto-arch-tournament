// rtl/ex_stage.sv
//
// Execute reads only the OF/EX operand flops. Owns EX/MEM and division.
//
// Latency:        1 cycle normally; divide launches, runs for six clocks,
//                 then transfers to EX/MEM on the next accepting edge.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  // Verification-only correction for unused raw instruction source fields.
  // These ports have no connection to execution or divider operands.
  input logic [4:0]          rvfi_mem_rd, rvfi_wb_rd,
  input logic               rvfi_mem_w_en, rvfi_wb_w_en,
  input logic [31:0]         rvfi_mem_data, rvfi_wb_data,
  output logic [4:0]         producer_rd,
  output logic              producer_w_en, normal_w_en, producer_load,
  output logic [31:0]        producer_result, normal_result,
  output ex_mem_t  out,
  output logic               div_wait,      // hold PC and ID/EX, drain MEM/WB
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               train_valid,
  output logic [5:0]         train_index,
  output logic               train_taken
);

  // No executing operand has a live RF, forwarding or dmem connection.
  logic [31:0] rs1;
  logic [31:0] rs2;
  assign rs1 = in.rs1_val;
  assign rs2 = in.rs2_val;

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    alu_a = in.ctrl.is_auipc ? in.pc  : rs1;
    alu_b = in.ctrl.alu_src  ? in.imm : rs2;
  end

  logic [31:0] alu_result;
  alu #(.COMBINATIONAL_DIV(1'b0), .SEPARATE_MUL_OPERANDS(1'b1)) u_alu (
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .mul_a (rs1),
    .mul_b (rs2),
    .out (alu_result)
  );

  logic is_div;
  logic div_active_q, div_start, div_consume;
  logic div_busy, div_result_valid;
  logic [31:0] div_result;
  ex_mem_t div_payload_q;

  assign is_div = in.valid && !in.ctrl.is_illegal &&
    (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU ||
     in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU);
  // Launch only from OF/EX flops when the older MEM request can advance.
  // Operand values and the exact instruction/RVFI payload share this edge.
  assign div_start = is_div && !div_active_q && !div_busy && !stall && !reset;
  assign div_consume = div_active_q && div_result_valid && !stall && !reset;
  assign div_wait = (is_div || div_active_q) && !div_consume;

  div_unit u_div (
    .clock (clock),
    .reset (reset),
    .start (div_start),
    .op (in.ctrl.alu_op),
    .a (in.rs1_val),
    .b (in.rs2_val),
    .consume (div_consume),
    .busy (div_busy),
    .result_valid (div_result_valid),
    .result (div_result)
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

  logic ex_accept, effective_taken;
  assign ex_accept = in.valid && !stall && !reset && !div_active_q && !is_div;
  assign effective_taken = branch_taken && !in.ctrl.is_illegal && !misalign_fault;
  assign redirect = ex_accept && !in.ctrl.is_illegal &&
    ((in.ctrl.is_branch && (effective_taken ^ in.predicted_taken)) ||
     (in.ctrl.is_jalr && !misalign_fault));
  // The registered prediction selects the conditional recovery address;
  // the late operand comparator only decides whether recovery is needed.
  assign redirect_target = in.ctrl.is_jalr ? jump_target
                         : in.predicted_taken ? (in.pc + 32'd4) : branch_target;

  assign train_valid = ex_accept && in.ctrl.is_branch &&
                       !in.ctrl.is_illegal && !misalign_fault;
  assign train_index = in.pc[7:2] ^ in.pc[13:8];
  assign train_taken = branch_cond;

  logic load_misalign;
  assign load_misalign = (in.ctrl.mem_width == 2 && alu_result[1:0] != 0) ||
                        (in.ctrl.mem_width == 1 && alu_result[0]);
  assign normal_result = in.ctrl.is_jump ? in.pc + 32'd4 : alu_result;
  assign normal_w_en = ex_accept && ctrl_with_trap.reg_write &&
                       !ctrl_with_trap.is_illegal && !in.ctrl.mem_read;
  assign producer_load = ex_accept && in.ctrl.mem_read &&
                         !in.ctrl.is_illegal && !load_misalign;
  assign producer_w_en = normal_w_en ||
    (div_consume && div_payload_q.ctrl.reg_write && !div_payload_q.ctrl.is_illegal);
  assign producer_rd = div_active_q ? div_payload_q.rd : in.rd;
  // Ordinary OF capture selects this completed-divide result separately
  // from normal_result, avoiding a cascaded wide data mux.
  assign producer_result = div_result;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;
  ex_mem_t next_payload;
  logic actual_rs1, actual_rs2;
  logic [31:0] metadata_rs1, metadata_rs2;

  assign actual_rs1 = !in.ctrl.is_illegal &&
    (in.instr[6:0] == 7'h33 || in.instr[6:0] == 7'h13 ||
     in.ctrl.mem_read || in.ctrl.mem_write || in.ctrl.is_branch || in.ctrl.is_jalr);
  assign actual_rs2 = !in.ctrl.is_illegal &&
    (in.instr[6:0] == 7'h33 || in.ctrl.mem_write || in.ctrl.is_branch);
  always_comb begin
    metadata_rs1 = rs1;
    metadata_rs2 = rs2;
    if (!actual_rs1 && in.rs1_addr != 0) begin
      if (rvfi_mem_w_en && rvfi_mem_rd == in.rs1_addr) metadata_rs1 = rvfi_mem_data;
      else if (rvfi_wb_w_en && rvfi_wb_rd == in.rs1_addr) metadata_rs1 = rvfi_wb_data;
    end
    if (!actual_rs2 && in.rs2_addr != 0) begin
      if (rvfi_mem_w_en && rvfi_mem_rd == in.rs2_addr) metadata_rs2 = rvfi_mem_data;
      else if (rvfi_wb_w_en && rvfi_wb_rd == in.rs2_addr) metadata_rs2 = rvfi_wb_data;
    end
  end

  always_comb begin
    next_payload = '0;
    next_payload.pc            = in.pc;
    next_payload.alu_result    = in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
    next_payload.write_data    = rs2;
    next_payload.rd            = in.rd;
    next_payload.rs1_addr      = in.rs1_addr;
    next_payload.rs2_addr      = in.rs2_addr;
    next_payload.rs1_val       = metadata_rs1;
    next_payload.rs2_val       = metadata_rs2;
    next_payload.pc_next       = misalign_fault     ? (in.pc + 32'd4)
                               : in.ctrl.is_jump   ? jump_target
                               : branch_taken      ? branch_target
                                                   : (in.pc + 32'd4);
    next_payload.branch_taken  = branch_taken;
    next_payload.branch_target = branch_target;
    next_payload.ctrl          = ctrl_with_trap;
    next_payload.instr         = in.instr;
    next_payload.valid         = in.valid;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      div_active_q <= 1'b0;
      div_payload_q <= '0;
    end else if (div_start) begin
      div_active_q <= 1'b1;
      div_payload_q <= next_payload;
    end else if (div_consume) begin
      div_active_q <= 1'b0;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (div_consume) begin
      reg_q <= div_payload_q;
      reg_q.alu_result <= div_result;
    end else if (div_wait) begin
      // The previous MEM instruction drains once. Never replay it while
      // EX waits, and never replace an outstanding stalled memory request.
      reg_q <= '0;
    end else begin
      reg_q <= next_payload;
    end
  end

  assign out = reg_q;

endmodule
