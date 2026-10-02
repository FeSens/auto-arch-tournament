// Execute consumes complete operand flops and registers every resolution
// with its EX/MEM instruction. Only an accepted MEM record can recover or
// train the frontend. Blocking operations retain their original payload
// and prediction snapshots until the completion edge.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,       // genuine older MEM wait
  input  logic               squash,      // accepted older MEM recovery
  input  logic               div_ready,
  // Raw and complete operands remain immutable throughout an EX hold.
  /* verilator lint_off UNUSEDSIGNAL */
  input  id_ex_t             in,
  /* verilator lint_on UNUSEDSIGNAL */
  output ex_mem_t            out,
  output logic [4:0]         next_rd,
  output logic               next_w_en,
  output logic [31:0]        next_data,
  output producer_tag_t      next_tag,
  output producer_t         fast_producer,
  output producer_t         link_producer,
  output producer_t         completed_producer,
  output logic              held_emit,
  output logic              fast_emit,
  output logic              link_emit,
  output logic              completed_emit,
  output logic               execute_busy,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               train_valid,
  output logic [31:0]        train_pc,
  output logic               train_eligible,
  output logic               train_jump,
  output logic               train_taken,
  output logic [31:0]        train_target
);
  localparam logic [1:0] P_DIV = 2'd0, P_MUL = 2'd1, P_JALR = 2'd2;
  ex_mem_t reg_q, payload, pending_payload_q;
  /* verilator lint_off UNUSEDSIGNAL */
  ex_mem_t reg_d;
  /* verilator lint_on UNUSEDSIGNAL */
  logic recovery_q, recovery_d;
  logic pending_q, pending_prediction_q;
  logic [31:0] pending_predicted_target_q;
  logic [1:0] pending_kind_q;
  logic is_mul, is_div, is_blocking, launch, pending_consume;
  logic completion_ready;
  logic fast_recovery, completed_recovery;
  ex_mem_t completed_payload;
  logic div_request, div_consume, div_busy, div_done;
  logic mul_request, mul_consume, mul_busy, mul_done;
  logic [31:0] alu_result, div_result, mul_result;

  assign is_div = (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU ||
                   in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU);
  assign is_mul = (in.ctrl.alu_op == ALU_MUL || in.ctrl.alu_op == ALU_MULH ||
                   in.ctrl.alu_op == ALU_MULHU || in.ctrl.alu_op == ALU_MULHSU);
  assign is_blocking = is_div || is_mul || in.ctrl.is_jalr;
  // A held MEM request prevents any younger unit from launching. Recovery
  // cancels units as well as pending metadata, so no orphan can stay busy.
  assign launch = in.valid && is_blocking && !pending_q && !stall && !reset && !squash;
  assign div_request = launch && is_div && !div_busy;
  assign mul_request = launch && is_mul && !mul_busy;
  assign completion_ready = (pending_kind_q == P_DIV && div_done && div_ready) ||
                            (pending_kind_q == P_MUL && mul_done) ||
                             pending_kind_q == P_JALR;
  assign pending_consume = pending_q && !stall && !reset && !squash && completion_ready;
  assign div_consume = pending_consume && pending_kind_q == P_DIV;
  assign mul_consume = pending_consume && pending_kind_q == P_MUL;
  // Squash controls register clearing and launch/consume directly. It does
  // not feed operand source-address selection through execute_busy.
  assign execute_busy = (pending_q || (in.valid && is_blocking)) &&
                       !(pending_q && !stall && !reset && completion_ready);
  alu u_alu (
    .clock(clock), .reset(reset || squash),
    .div_request(div_request), .div_consume(div_consume),
    .mul_request(mul_request), .mul_consume(mul_consume),
    .op(in.ctrl.alu_op), .a(in.alu_a_val), .b(in.alu_b_val),
    .out(alu_result), .div_busy(div_busy), .div_done(div_done),
    .div_result(div_result), .mul_busy(mul_busy), .mul_done(mul_done),
    .mul_result(mul_result)
  );

  logic branch_cond, branch_taken, misalign_fault;
  logic [31:0] target;
  ctrl_t ctrl_with_trap;
  always_comb begin
    case (in.ctrl.branch_op)
      BR_BEQ:  branch_cond = in.rs1_val == in.rs2_val;
      BR_BNE:  branch_cond = in.rs1_val != in.rs2_val;
      BR_BLT:  branch_cond = $signed(in.rs1_val) < $signed(in.rs2_val);
      BR_BGE:  branch_cond = $signed(in.rs1_val) >= $signed(in.rs2_val);
      BR_BLTU: branch_cond = in.rs1_val < in.rs2_val;
      BR_BGEU: branch_cond = in.rs1_val >= in.rs2_val;
      default: branch_cond = 1'b0;
    endcase
    branch_taken = in.ctrl.is_branch && branch_cond;
    // JALR's ADD uses the complete captured rs1/immediate operands.
    target = in.ctrl.is_jalr ? {alu_result[31:1], 1'b0} : in.direct_target;
    misalign_fault = (branch_taken || in.ctrl.is_jump) && target[1:0] != 2'b00;
    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write = 1'b0;
    end

    payload = '0;
    if (in.valid) begin
      payload.pc = in.pc;
      payload.alu_result = in.ctrl.is_jump ? in.pc + 32'd4 : alu_result;
      payload.write_data = in.rs2_val;
      payload.rd = in.rd;
      payload.rs1_addr = in.rs1_addr;
      payload.rs2_addr = in.rs2_addr;
      payload.rs1_val = in.rs1_val;
      payload.rs2_val = in.rs2_val;
      payload.pc_next = !ctrl_with_trap.is_illegal && (branch_taken || in.ctrl.is_jump)
                      ? target : in.pc + 32'd4;
      payload.branch_taken = branch_taken;
      payload.branch_target = target;
      payload.ctrl = ctrl_with_trap;
      payload.instr = in.instr;
      payload.valid = 1'b1;
    end
  end

  // Effective next producer and recovery record use the same register
  // update priorities. A squash emits a completely zeroed bubble, while
  // the accepted resolving reg_q still proceeds through MEM to WB.
  always_comb begin
    fast_recovery = 1'b0;
    if (in.valid) begin
      fast_recovery = in.prediction_selected;
      if (!ctrl_with_trap.is_illegal) begin
        if (in.ctrl.is_branch)
          fast_recovery = (in.prediction_selected != branch_taken) ||
                       (branch_taken && !in.direct_target_match);
        else if (in.ctrl.is_jump)
          fast_recovery = !in.prediction_selected || !in.direct_target_match;
      end
    end
    completed_payload = pending_payload_q;
    if (pending_kind_q == P_DIV) completed_payload.alu_result = div_result;
    if (pending_kind_q == P_MUL) completed_payload.alu_result = mul_result;
    completed_recovery = pending_prediction_q;
    if (!pending_payload_q.ctrl.is_illegal && pending_kind_q == P_JALR)
      completed_recovery = !pending_prediction_q ||
                          pending_payload_q.branch_target != pending_predicted_target_q;
  end

  // Mutually exclusive next-state sources avoid a priority mux ahead of
  // the destination matcher and operand capture bank.
  assign held_emit = !reset && stall;
  assign completed_emit = pending_consume;
  assign fast_emit = !reset && !stall && !squash && !pending_q && in.valid && !is_blocking;
  assign reg_d = (reg_q & {295{held_emit}})
               | (completed_payload & {295{completed_emit}})
               | (payload & {295{fast_emit}});
  assign recovery_d = (recovery_q && held_emit)
                    || (completed_recovery && completed_emit)
                    || (fast_recovery && fast_emit);

  assign next_rd = reg_d.rd;
  // A load's EX result is its address, never available register data.
  assign next_w_en = (held_emit && reg_q.valid && reg_q.ctrl.reg_write && !reg_q.ctrl.mem_read)
                  || (completed_emit && pending_payload_q.ctrl.reg_write && !pending_payload_q.ctrl.mem_read)
                  || (fast_emit && fast_producer.w_en);
  assign next_data = reg_d.alu_result;
  // Include loads as possible writers, but never forward their addresses.
  // These metadata selections use exactly the EX/MEM update priorities.
  assign next_tag.rd = reg_d.rd;
  assign next_tag.writer = (held_emit && reg_q.valid && reg_q.ctrl.reg_write)
                        || (completed_emit && pending_payload_q.valid && pending_payload_q.ctrl.reg_write)
                        || (fast_emit && in.ctrl.reg_write);
  // Compare candidate destinations before the late bus/consume controls.
  // These are the same concrete sources that form effective next state.
  assign fast_producer.rd = payload.rd;
  // Fast advancement excludes JALR. Only a direct jump can both write
  // a register and trap on a control target; branches never write rd.
  // Keep branch comparison out of the arithmetic capture eligibility.
  assign fast_producer.w_en = in.valid && in.ctrl.reg_write && !in.ctrl.mem_read &&
                             (!in.ctrl.is_jump || in.direct_target[1:0] == 2'b00);
  // Select a jump link in the capture mux, alongside the other sources,
  // rather than placing a PC/link mux after the arithmetic result.
  assign fast_producer.data = alu_result;
  assign link_producer.rd = fast_producer.rd;
  assign link_producer.w_en = fast_producer.w_en;
  assign link_producer.data = in.pc + 32'd4;
  assign link_emit = fast_emit && in.ctrl.is_jump;
  assign completed_producer.rd = pending_payload_q.rd;
  assign completed_producer.w_en = pending_payload_q.valid &&
                                 pending_payload_q.ctrl.reg_write && !pending_payload_q.ctrl.mem_read;
  assign completed_producer.data = completed_payload.alu_result;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
      recovery_q <= 1'b0;
      pending_payload_q <= '0;
      pending_q <= 1'b0;
      pending_kind_q <= P_DIV;
      pending_prediction_q <= 1'b0;
      pending_predicted_target_q <= '0;
    end else begin
      reg_q <= reg_d;
      recovery_q <= recovery_d;
      if (squash) begin
        pending_payload_q <= '0;
        pending_q <= 1'b0;
        pending_kind_q <= P_DIV;
        pending_prediction_q <= 1'b0;
        pending_predicted_target_q <= '0;
      end else if (div_request || mul_request || (launch && in.ctrl.is_jalr)) begin
        pending_payload_q <= payload;
        pending_q <= 1'b1;
        pending_kind_q <= is_div ? P_DIV : is_mul ? P_MUL : P_JALR;
        pending_prediction_q <= in.prediction_selected;
        pending_predicted_target_q <= in.predicted_target;
      end else if (pending_consume) pending_q <= 1'b0;
    end
  end

  // MEM acceptance depends only on this registered instruction and the
  // genuine older memory hold. Unrelated bus readiness and younger work
  // cannot block nonmemory resolution. Training applies once, including
  // on the resolving record's redirect edge; squashed work never trains.
  assign train_valid = reg_q.valid && !stall && !reset;
  assign redirect = train_valid && recovery_q;
  assign redirect_target = reg_q.pc_next;
  assign train_pc = reg_q.pc;
  assign train_eligible = !reg_q.ctrl.is_illegal &&
                         (reg_q.ctrl.is_branch || reg_q.ctrl.is_jump) &&
                         reg_q.branch_target[1:0] == 2'b00;
  assign train_jump = reg_q.ctrl.is_jump;
  assign train_taken = reg_q.branch_taken || reg_q.ctrl.is_jump;
  assign train_target = reg_q.branch_target;
  assign out = reg_q;
endmodule
