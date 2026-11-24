// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, and registers fetch resolution and BTB training
// alongside the EX/MEM pipeline register.
//
// Latency:        1 cycle (EX/MEM register clocked here), plus 8 cycles
//                 for divide/remainder launch and restoring updates.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  logic               squash_candidate,
  // Dependency matches are consumed by forward_unit.
  /* verilator lint_off UNUSEDSIGNAL */
  input  id_ex_t             in,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [31:0]        fetch_pc,
  input  logic               fetch_parked,
  input  fwd_sel_t           fwd_rs1_sel,
  input  fwd_sel_t           fwd_rs2_sel,
  input  logic [31:0]        fwd_other,
  input  logic [31:0]        fwd_add,
  input  logic [31:0]        fwd_shift,
  input  logic [31:0]        fwd_div,
  input  logic [31:0]        fwd_mul,
  input  logic [31:0]        fwd_load_rs1,
  input  logic [31:0]        fwd_load_rs2,
  input  logic [31:0]        load_address_data,
  input  logic               mem_load_word,
  input  logic [31:0]        fwd_mem_wb,
  output ex_mem_t             out,
  output logic               div_wait,
  output logic               load_replay,
  output logic               replay_consumer,
  output logic [1:0]         replay_load_match,
  output logic [31:0]        replay_rs1,
  output logic [31:0]        replay_rs2,
  output fetch_resolution_t  fetch_resolution,
  output btb_training_t      btb_training,
  output logic               training_taken,
  output logic [31:0]        pc_next,
  output logic               control_misalign
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;
  logic [31:0] live_rs1, live_rs2;
  logic [1:0]  live_load;

  assign rs1 = ({32{fwd_rs1_sel.result.other}} & fwd_other)
             | ({32{fwd_rs1_sel.result.add}}   & fwd_add)
             | ({32{fwd_rs1_sel.result.shift}} & fwd_shift)
             | ({32{fwd_rs1_sel.result.div}}   & fwd_div)
             | ({32{fwd_rs1_sel.result.mul}}   & fwd_mul)
             | ({32{fwd_rs1_sel.wb}}           & fwd_mem_wb)
             | ({32{fwd_rs1_sel.regfile}}      & in.rs1_val);
  assign rs2 = ({32{fwd_rs2_sel.result.other}} & fwd_other)
             | ({32{fwd_rs2_sel.result.add}}   & fwd_add)
             | ({32{fwd_rs2_sel.result.shift}} & fwd_shift)
             | ({32{fwd_rs2_sel.result.div}}   & fwd_div)
             | ({32{fwd_rs2_sel.result.mul}}   & fwd_mul)
             | ({32{fwd_rs2_sel.wb}}           & fwd_mem_wb)
             | ({32{fwd_rs2_sel.regfile}}      & in.rs2_val);

  // The forwarding selectors give a live load priority over any older
  // writer. Formatted data is also needed for both raw RVFI fields.
  assign live_rs1 = rs1 | fwd_load_rs1;
  assign live_rs2 = rs2 | fwd_load_rs2;
  assign live_load = {fwd_rs2_sel.result.load, fwd_rs1_sel.result.load};
  assign load_replay = in.valid && !in.ctrl.branch_equality
                     && ((in.ctrl.uses_rs[0] && live_load[0] && !(in.ctrl.mem_read && mem_load_word))
                         || (in.ctrl.uses_rs[1] && live_load[1]));
  assign replay_consumer = load_replay && !stall && !squash_candidate;
  assign replay_load_match = live_load;
  assign replay_rs1 = rs1;
  assign replay_rs2 = rs2;

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    alu_a = in.ctrl.is_auipc ? in.pc  : rs1;
    alu_b = in.ctrl.alu_src  ? in.imm : rs2;
  end

  logic [31:0] other_result, add_result, shift_result, div_result, mul_result;
  logic        select_mul, select_div;
  logic        is_div, div_start, div_busy, div_valid, div_consume;
  logic [31:0] div_rs1_q, div_rs2_q;

  assign select_div = in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU
                   || in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU;
  assign is_div = in.valid && select_div;
  assign div_wait = is_div && !div_valid;
  assign div_start = is_div && !stall && !squash_candidate && !load_replay && !div_busy;
  assign div_consume = is_div && !stall && !squash_candidate && div_valid;

  // ID/EX holds the instruction until completion. The forwarding
  // sources can drain in the meantime, so save the launch values for RVFI.
  always_ff @(posedge clock) begin
    if (div_start) begin
      div_rs1_q <= rs1;
      div_rs2_q <= rs2;
    end
  end

  alu #(.SPLIT_MULTIPLY(1'b1)) u_alu (
    .clock        (clock),
    .reset        (reset),
    .op           (in.ctrl.alu_op),
    .a            (alu_a),
    .b            (alu_b),
    .mul_a        (rs1),
    .mul_b        (rs2),
    .div_start    (div_start),
    .div_consume  (div_consume),
    .div_busy     (div_busy),
    .div_valid    (div_valid),
    /* verilator lint_off PINCONNECTEMPTY */
    .out          (),
    /* verilator lint_on PINCONNECTEMPTY */
    .mul_result   (mul_result),
    .mul_select   (select_mul),
    .add_result   (add_result),
    .shift_result (shift_result),
    .div_result   (div_result),
    .other_result (other_result)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        ordered_branch_cond;
  logic        target_aligned, take_target;
  logic        ex_ready, advance;
  logic [31:0] target, jalr_sum, effective_addr;
  logic [31:0] target_q, fallthrough_q;
  logic        target_aligned_q, match_target_q, match_fallthrough_q;
  logic        equality_q, branch_invert_q, fixed_taken_q, resolve_valid_q, refetch_q;
  logic [3:0]  live_byte_eq, live_byte_eq_q;

  // Compare the forwarded operands in byte groups. Each less-than carry
  // chain is eight bits and the higher equal groups qualify the result.
  logic [3:1] branch_byte_eq;
  logic [3:0] branch_byte_lt;
  logic branch_lt, branch_signed_lt;

  for (genvar i = 0; i < 4; i++) begin : branch_compare
    if (i > 0) begin : upper_byte
      assign branch_byte_eq[i] = rs1[i*8 +: 8] == rs2[i*8 +: 8];
    end
    assign branch_byte_lt[i] = rs1[i*8 +: 8] < rs2[i*8 +: 8];
    assign live_byte_eq[i] = live_rs1[i*8 +: 8] == live_rs2[i*8 +: 8];
  end

  assign branch_lt = branch_byte_lt[3]
                  || (branch_byte_eq[3] && branch_byte_lt[2])
                  || ((&branch_byte_eq[3:2]) && branch_byte_lt[1])
                  || ((&branch_byte_eq[3:1]) && branch_byte_lt[0]);
  assign branch_signed_lt = (rs1[31] == rs2[31]) ? branch_lt : rs1[31];

  always_comb begin
    case (in.ctrl.branch_op)
      BR_BLT:  ordered_branch_cond = branch_signed_lt;
      BR_BGE:  ordered_branch_cond = !branch_signed_lt;
      BR_BLTU: ordered_branch_cond = branch_lt;
      BR_BGEU: ordered_branch_cond = !branch_lt;
      default: ordered_branch_cond = 1'b0;
    endcase
  end

  assign jalr_sum = rs1 + in.imm;
  assign effective_addr = (rs1 | load_address_data) + in.imm;
  assign target = in.ctrl.is_jalr ? (jalr_sum & 32'hffff_fffe) : in.direct_target;
  assign target_aligned = target[1:0] == 2'b00;
  assign ex_ready = in.valid && !squash_candidate && !load_replay && !div_wait;
  assign advance = ex_ready && !stall;

  logic train_valid, train_target_q, train_taken_counter_q, train_not_taken_counter_q;
  logic [17:0] train_pc_word_q;
  logic [1:0] train_up, train_up_q, train_down, train_down_q;

  assign training_taken = fixed_taken_q || (equality_q && ((&live_byte_eq_q) ^ branch_invert_q));
  assign take_target = training_taken && target_aligned_q;
  assign control_misalign = training_taken && !target_aligned_q;
  assign pc_next = take_target ? target_q : fallthrough_q;

  assign fetch_resolution.target = target_q;
  assign fetch_resolution.fallthrough = fallthrough_q;
  assign fetch_resolution.match_target = match_target_q;
  assign fetch_resolution.match_fallthrough = match_fallthrough_q;
  assign fetch_resolution.take_target = take_target;
  assign fetch_resolution.valid = resolve_valid_q;
  assign fetch_resolution.refetch = refetch_q;

  assign train_valid = !in.ctrl.is_illegal && in.pc[31:20] == 12'b0 && in.pc[1:0] == 2'b00;
  assign btb_training.pc_word = train_pc_word_q;
  assign btb_training.target_word = target_q[19:2];
  assign btb_training.taken.write_target = resolve_valid_q && train_target_q;
  assign btb_training.taken.write_counter = resolve_valid_q && train_taken_counter_q;
  assign btb_training.taken.counter = train_up_q;
  assign btb_training.not_taken.write_target = 1'b0;
  assign btb_training.not_taken.write_counter = resolve_valid_q && train_not_taken_counter_q;
  assign btb_training.not_taken.counter = train_down_q;

  always_comb begin
    if (in.ctrl.is_jump)
      train_up = 2'b11;
    else if (!in.btb_hit)
      train_up = 2'b10;
    else
      train_up = in.btb_counter == 2'b11 ? 2'b11 : in.btb_counter + 2'd1;
  end
  assign train_down = in.btb_counter == 2'b00 ? 2'b00 : in.btb_counter - 2'd1;

  // Keep the comparison and successors aligned with EX/MEM for RVFI.
  // Recovery and training announce the advance once, even on a MEM hold.
  always_ff @(posedge clock) begin
    resolve_valid_q <= !reset && advance;
    refetch_q       <= !reset && advance && in.instr[6:0] == 7'b0001111
                       && in.instr[14:12] == 3'b001;
    if (!stall) begin
      target_q            <= target;
      fallthrough_q       <= in.pc_plus4;
      target_aligned_q    <= target_aligned;
      match_target_q      <= !fetch_parked && fetch_pc == target;
      match_fallthrough_q <= !fetch_parked && fetch_pc == in.pc_plus4;
      equality_q          <= in.ctrl.branch_equality;
      branch_invert_q     <= in.ctrl.branch_op[0];
      live_byte_eq_q      <= live_byte_eq;
      fixed_taken_q       <= in.ctrl.is_jump || (in.ctrl.is_branch && ordered_branch_cond);
    end

    train_pc_word_q           <= in.pc[19:2];
    train_target_q            <= train_valid && target_aligned && target[31:20] == 12'b0;
    train_taken_counter_q     <= train_valid && target_aligned
                                && (target[31:20] == 12'b0 || (in.ctrl.is_branch && in.btb_hit));
    train_not_taken_counter_q <= train_valid && in.ctrl.is_branch && in.btb_hit;
    train_up_q                <= train_up;
    train_down_q              <= train_down;
  end

  ctrl_t mem_ctrl;
  always_comb begin
    mem_ctrl = in.ctrl;
    mem_ctrl.reg_write = in.ctrl.reg_write && !(in.ctrl.is_jump && !target_aligned);
  end

  result_sel_t result_sel;
  logic select_add, select_shift;

  assign select_add = !in.ctrl.mem_to_reg && !in.ctrl.is_jump
                   && (in.ctrl.alu_op == ALU_ADD || in.ctrl.alu_op == ALU_SUB);
  assign select_shift = in.ctrl.alu_op == ALU_SLL || in.ctrl.alu_op == ALU_SRL
                     || in.ctrl.alu_op == ALU_SRA;
  assign result_sel.add   = select_add;
  assign result_sel.shift = select_shift;
  assign result_sel.div   = select_div;
  assign result_sel.mul   = select_mul;
  assign result_sel.load  = in.ctrl.mem_to_reg;
  assign result_sel.other = !(select_add || select_shift || select_div || select_mul
                             || in.ctrl.mem_to_reg);

  // Decode the address lanes in EX. In MEM only the response data is new.
  logic [1:0] addr_low;
  logic load_word, half_lo, half_hi, mem_misalign;
  logic [3:0] byte_sel, mid_sign, high_sign;
  load_format_t load_format;

  assign addr_low = effective_addr[1:0];
  assign load_word = in.ctrl.mem_width[1];
  assign half_lo = in.ctrl.mem_width == 2'd1 && !addr_low[1];
  assign half_hi = in.ctrl.mem_width == 2'd1 &&  addr_low[1];
  assign byte_sel = in.ctrl.mem_width == 2'd0 ? 4'b0001 << addr_low : 4'b0000;
  assign mid_sign = {4{in.ctrl.mem_sext}} & byte_sel;
  assign high_sign = {4{in.ctrl.mem_sext}} & (byte_sel | {half_hi, 1'b0, half_lo, 1'b0});
  assign load_format.low_bytes = byte_sel | {1'b0, half_hi, 1'b0, load_word || half_lo};
  assign load_format.mid_bytes = {half_hi, load_word || half_lo};
  assign load_format.high_half = load_word;
  assign load_format.mid_sign = mid_sign;
  assign load_format.high_sign = high_sign;
  // Bits 15 and 31 can come from either extension or a response byte's MSB.
  assign load_format.bit15 = mid_sign | {half_hi, 1'b0, load_word || half_lo, 1'b0};
  assign load_format.bit31 = high_sign | {load_word, 3'b000};
  assign mem_misalign = (in.ctrl.mem_read || in.ctrl.mem_write)
                      && ((in.ctrl.mem_width == 2'd2 && addr_low != 2'b00)
                          || (in.ctrl.mem_width == 2'd1 && addr_low[0]));

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (!stall) begin
      reg_q.pc             <= in.pc;
      reg_q.other_result   <= in.ctrl.is_jump ? in.pc_plus4 : other_result;
      reg_q.add_result     <= add_result;
      reg_q.shift_result   <= shift_result;
      reg_q.div_result     <= div_result;
      reg_q.mul_result     <= mul_result;
      reg_q.result_sel     <= ex_ready ? result_sel : '0;
      reg_q.effective_addr <= effective_addr;
      reg_q.load_format    <= load_format;
      reg_q.mem_misalign   <= ex_ready && mem_misalign;
      reg_q.write_data     <= rs2;
      reg_q.rd             <= in.rd;
      reg_q.rs1_addr       <= in.rs1_addr;
      reg_q.rs2_addr       <= in.rs2_addr;
      reg_q.rs1_val        <= div_consume ? div_rs1_q : live_rs1;
      reg_q.rs2_val        <= div_consume ? div_rs2_q : live_rs2;
      reg_q.ctrl           <= ex_ready ? mem_ctrl : '0;
      reg_q.instr          <= in.instr;
      reg_q.valid          <= ex_ready;
    end
  end

  assign out = reg_q;

endmodule
