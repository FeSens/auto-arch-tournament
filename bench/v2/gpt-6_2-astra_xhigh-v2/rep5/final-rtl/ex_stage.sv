// rtl/ex_stage.sv
//
// Execute stage. Bypass the adjacent producer when needed, run the ALU
// and resolve branch targets. Owns the EX/MEM pipeline register.
//
// Latency:        9 EX cycles for DIV/REM, 1 for other instructions.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  input  logic               capture_operands,
  input  logic               id_rs1_match,
  input  logic               id_rs2_match,
  input  load_word_t         ready_word,
  input  load_word_t         pending_word,
  input  logic [9:0]         pending_row,
  input  logic               ready_eligible,
  input  logic               pending_eligible,
  input  logic               ready_ram,
  input  logic               pending_base,
  input  logic [3:0]         pending_lanes,
  input  logic [1:0]         ready_lane,
  input  logic               ready_carry,
  output logic               load_hit,
  output ex_mem_t  out,
  output logic               div_wait,
  output logic               redirect,
  output logic [31:2]        redirect_target,
  output logic               train,
  output logic [1:0]         train_counter
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  ex_mem_t reg_q;
  logic [31:0] product_low, product_high;
  logic rs1_ordinary_q, rs1_mul_q, rs1_high_q;
  logic rs2_ordinary_q, rs2_mul_q, rs2_high_q;
  logic [31:0] rs1, rs2;

  assign rs1 = rs1_mul_q ? (rs1_high_q ? product_high : product_low)
                         : (rs1_ordinary_q ? reg_q.alu_result : in.rs1_val);
  assign rs2 = rs2_mul_q ? (rs2_high_q ? product_high : product_low)
                         : (rs2_ordinary_q ? reg_q.alu_result : in.rs2_val);

  // The ready row includes the displacement. Its page is the captured
  // base page exactly when the low sum's carry cancels the immediate sign.
  logic [31:0] mem_addr, raw_word, predicted_data, ready_data, pending_data;
  logic [1:0] pending_lane;
  logic ready_hit, pending_hit;
  assign mem_addr = rs1 + in.imm;
  assign ready_hit = ready_ram && ready_eligible && ready_word.valid &&
                     in.rs1_val[19:12] == ready_word.page &&
                     ready_carry == in.imm[11];

  // Pending probes cover displacements 0..3. Verify the ordinary EX/MEM
  // base directly, including the row speculated from an ADD, ADDI or LW.
  assign pending_lane = reg_q.alu_result[1:0] + in.imm[1:0];
  assign pending_hit = pending_base && pending_eligible && pending_word.valid &&
                       reg_q.alu_result[31:2] == {12'b0, pending_word.page, pending_row} &&
                       pending_lanes[reg_q.alu_result[1:0]];
  assign load_hit = in.ctrl.mem_read && (ready_hit || pending_hit);
  assign raw_word = pending_base ? pending_word.data : ready_word.data;
  assign ready_data = extend_load(ready_word.data, ready_lane, in.ctrl.mem_width, in.ctrl.mem_sext);
  assign pending_data = extend_load(pending_word.data, pending_lane, in.ctrl.mem_width, in.ctrl.mem_sext);
  assign predicted_data = pending_base ? pending_data : ready_data;

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    alu_a = in.ctrl.is_auipc ? in.pc  : rs1;
    alu_b = in.ctrl.alu_src  ? in.imm : rs2;
  end

  logic [31:0] alu_result;
  logic mul_low, mul_high;
  logic use_low_q, use_high_q, use_ordinary_q;
  logic is_div, div_ready, div_start, div_valid, div_consume;
  logic [31:0] div_result, div_rs1_q, div_rs2_q;

  assign is_div = in.valid && (in.ctrl.alu_op == ALU_DIV  || in.ctrl.alu_op == ALU_DIVU ||
                               in.ctrl.alu_op == ALU_REM  || in.ctrl.alu_op == ALU_REMU);
  assign div_start = is_div && div_ready && !stall;
  assign div_consume = div_valid && !stall;
  assign div_wait = is_div && !div_valid;
  assign mul_low = in.ctrl.alu_op == ALU_MUL;
  assign mul_high = in.ctrl.alu_op == ALU_MULH || in.ctrl.alu_op == ALU_MULHSU ||
                    in.ctrl.alu_op == ALU_MULHU;

  // ID/EX holds the instruction throughout the divide. Forwarding sources
  // can drain on the issue edge, so preserve the values EX actually used.
  always_ff @(posedge clock) begin
    if (div_start) begin
      div_rs1_q <= rs1;
      div_rs2_q <= rs2;
    end
  end

  alu u_alu (
    .clock (clock),
    .reset (reset),
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result),
    .mul_rs1     (rs1),
    .mul_rs2     (rs2),
    .advance     (!stall),
    .product_low (product_low),
    .product_high(product_high),
    .div_start   (div_start),
    .div_ready   (div_ready),
    .div_valid   (div_valid),
    .div_consume (div_consume),
    .div_result  (div_result)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        take_transfer, actual_taken, misalign_fault;
  logic [31:0] target;
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
  end

  assign jalr_sum = rs1 + {{20{in.instr[31]}}, in.instr[31:20]};
  assign target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0} : in.direct_target;
  assign take_transfer = in.ctrl.is_jump || (in.ctrl.is_branch && branch_cond);
  assign misalign_fault = take_transfer && target[1:0] != 2'b00;
  assign actual_taken = take_transfer && target[1:0] == 2'b00;

  ctrl_t ctrl_with_trap;

  always_comb begin
    ctrl_with_trap = in.ctrl;
    // Branches have no destination. Only a faulting jump can suppress a
    // register write, so forwarding control need not wait for branch_cond.
    ctrl_with_trap.reg_write = in.ctrl.reg_write && !(in.ctrl.is_jump && target[1:0] != 0);
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
    end
  end

  // A predicted JALR has the exact target. Only an unpredicted JALR can
  // need recovery, so direct transfers alone use the registered alternative.
  assign redirect = in.valid && !stall && (in.predicted_taken != actual_taken);
  assign redirect_target = in.ctrl.is_jalr ? jalr_sum[31:2] : in.alternate_pc;

  assign train = in.valid && !stall && in.ctrl.is_branch && !misalign_fault;
  always_comb begin
    if (branch_cond)
      train_counter = in.counter == 2'b11 ? in.counter : in.counter + 2'd1;
    else
      train_counter = in.counter == 2'b00 ? in.counter : in.counter - 2'd1;
  end

  // The same write permission controls forwarding and the EX/MEM write.
  // Capture the bank selections on the edge that accepts ID's operands.
  logic ordinary_writer, mul_writer, high_writer;
  assign ordinary_writer = ctrl_with_trap.reg_write && !(mul_low || mul_high);
  assign mul_writer      = ctrl_with_trap.reg_write && (mul_low || mul_high);
  assign high_writer     = ctrl_with_trap.reg_write && mul_high;

  always_ff @(posedge clock) begin
    if (capture_operands) begin
      rs1_ordinary_q <= id_rs1_match && ordinary_writer;
      rs1_mul_q      <= id_rs1_match && mul_writer;
      rs1_high_q     <= id_rs1_match && high_writer;
      rs2_ordinary_q <= id_rs2_match && ordinary_writer;
      rs2_mul_q      <= id_rs2_match && mul_writer;
      rs2_high_q     <= id_rs2_match && high_writer;
    end
  end

  // ── EX/MEM register ───────────────────────────────────────────────────
  always_ff @(posedge clock) begin
    if (!stall) begin
      use_low_q           <= mul_low;
      use_high_q          <= mul_high;
      use_ordinary_q      <= !(mul_low || mul_high);
      reg_q.pc            <= in.pc;
      reg_q.alu_result    <= in.ctrl.mem_read ? predicted_data :
                             div_valid ? div_result : alu_result;
      reg_q.mem_addr      <= mem_addr;
      reg_q.load_hit      <= load_hit;
      reg_q.load_word     <= raw_word;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= div_valid ? div_rs1_q : rs1;
      reg_q.rs2_val       <= div_valid ? div_rs2_q : rs2;
      reg_q.pc_next       <= actual_taken ? target : in.pc_plus4;
      reg_q.instr         <= in.instr;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q.ctrl  <= '0;
      reg_q.valid <= 1'b0;
    end else if (!stall) begin
      reg_q.ctrl  <= div_wait ? '0 : ctrl_with_trap;
      reg_q.valid <= in.valid && !div_wait;
    end
  end

  always_comb begin
    out = reg_q;
    out.alu_result = ({32{use_ordinary_q}} & reg_q.alu_result) |
                     ({32{use_low_q}} & product_low) |
                     ({32{use_high_q}} & product_high);
  end

endmodule
