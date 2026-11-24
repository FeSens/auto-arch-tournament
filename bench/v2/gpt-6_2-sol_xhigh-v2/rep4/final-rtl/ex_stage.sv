// rtl/ex_stage.sv
//
// Execute stage. Applies the registered operand masks, runs the ALU and
// resolves transfers. Owns the EX/MEM pipeline register.
//
// Latency:        1 cycle, plus 2 for high multiplies or 9 for divides.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  input  logic               branch_correction,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // MEM/WB.write_value (registered)
  input  logic [31:0]        raw_load,
  input  load_response_t     load_response,
  output ex_mem_t  out,
  output logic               write_eligible,   // EX producer for decode
  output logic               arithmetic_wait,  // ordinary ID/EX hold
  output logic               redirect,
  output logic               fence_i,
  output logic               direct_taken,
  output logic               recover_indirect,
  output logic [31:0]        sequential_pc,
  output logic [31:0]        direct_target,
  output logic [5:0]         indirect_index,
  output branch_resolution_t branch,
  output logic [5:0]         train_index,
  output logic               train_negative
);

  logic valid;
  assign valid = in.valid && !branch_correction;

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;
  logic [31:0] alu_a;
  logic [31:0] alu_b;

  assign rs1 = ({32{in.rs1_sel[2]}} & fwd_ex_mem)
             | ({32{in.rs1_sel[1]}} & fwd_mem_wb)
             | ({32{in.rs1_sel[0]}} & in.rs1_val);
  assign rs2 = ({32{in.rs2_sel[2]}} & fwd_ex_mem)
             | ({32{in.rs2_sel[1]}} & fwd_mem_wb)
             | ({32{in.rs2_sel[0]}} & in.rs2_val);
  assign alu_a = ({32{in.alu_a_sel[2]}} & fwd_ex_mem)
               | ({32{in.alu_a_sel[1]}} & fwd_mem_wb)
               | ({32{in.alu_a_sel[0]}} & in.alu_a_base);
  assign alu_b = ({32{in.alu_b_sel[2]}} & fwd_ex_mem)
               | ({32{in.alu_b_sel[1]}} & fwd_mem_wb)
               | ({32{in.alu_b_sel[0]}} & in.alu_b_base);

  logic [31:0] alu_result, ordinary_addr, effective_addr;
  alu u_alu (
    .op      (in.ctrl.alu_op),
    .a       (alu_a),
    .b       (alu_b),
    .out     (alu_result),
    .add_sum (ordinary_addr)
  );

  // ID selects forwarded rs1 and the immediate for the full address sum.
  // JALR needs only bit 1 for alignment, independently of the full sum.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [1:0] jalr_addr_low;
  /* verilator lint_on UNUSEDSIGNAL */
  assign jalr_addr_low = rs1[1:0] + in.addr_offset[1:0];

  // Form the recovery hash alongside the address, with an independent
  // low-byte carry for the upper half of the hash.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [8:0] jalr_low_byte;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [5:0] jalr_high_bits;
  assign jalr_low_byte = {1'b0, rs1[7:0]} + {1'b0, in.addr_offset[7:0]};
  assign jalr_high_bits = rs1[13:8] + {{2{in.addr_offset[11]}}, in.addr_offset[11:8]}
                        + {5'b0, jalr_low_byte[8]};
  always_ff @(posedge clock) begin
    indirect_index <= jalr_low_byte[7:2] ^ jalr_high_bits;
  end

  // Carry into each upper slice of the short-offset response address
  // is computed in parallel from the raw word.
  logic [31:0] load_addr;
  logic [2:0] short_sum;
  logic use_load_addr;
  assign short_sum = {1'b0, raw_load[1:0]} + {1'b0, in.addr_offset[1:0]};
  assign load_addr[1:0] = short_sum[1:0];
  for (genvar bit_lo = 2; bit_lo < 32; bit_lo += 6) begin : gen_load_addr
    logic carry;
    if (bit_lo == 2) begin : gen_low_slice
      assign carry = short_sum[2];
    end else begin : gen_upper_slice
      assign carry = short_sum[2] && (&raw_load[bit_lo-1:2]);
    end
    assign load_addr[bit_lo+:6] = raw_load[bit_lo+:6] + {5'b0, carry};
  end
  assign use_load_addr = in.load_address && load_response.valid;
  assign effective_addr = use_load_addr ? load_addr : ordinary_addr;

  // ── RV32M arithmetic ──────────────────────────────────────────────────
  logic        mul_low_instr;
  logic        mul_high_op, mul_high_instr, mul_start, mul_ready, mul_done;
  logic        div_op, div_instr, div_start, div_ready, div_done;
  logic [31:0] mul_low_result, mul_high_result, div_result;
  logic [31:0] issued_rs1_q, issued_rs2_q;

  assign mul_low_instr = in.ctrl.alu_op == ALU_MUL;
  assign mul_high_op = in.ctrl.alu_op == ALU_MULH   || in.ctrl.alu_op == ALU_MULHSU ||
                       in.ctrl.alu_op == ALU_MULHU;
  assign div_op = in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU ||
                  in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU;
  assign mul_high_instr = valid && mul_high_op;
  assign div_instr = valid && div_op;
  assign arithmetic_wait = in.valid && ((mul_high_op && !mul_done) || (div_op && !div_done));
  assign mul_start = mul_high_instr && mul_ready && !stall;
  assign div_start = div_instr && div_ready && !stall;

  mul_unit u_mul (
    .clock       (clock),
    .reset       (reset),
    .start       (mul_start),
    .consume     (mul_high_instr && mul_done && !stall),
    .op          (in.ctrl.alu_op),
    .a           (rs1),
    .b           (rs2),
    .ready       (mul_ready),
    .done        (mul_done),
    .low_result  (mul_low_result),
    .high_result (mul_high_result)
  );

  div_unit u_div (
    .clock   (clock),
    .reset   (reset),
    .start   (div_start),
    .consume (div_instr && div_done && !stall),
    .op      (in.ctrl.alu_op),
    .a       (rs1),
    .b       (rs2),
    .ready   (div_ready),
    .done    (div_done),
    .result  (div_result)
  );

  // Forwarding sources can drain while a multicycle operation is in EX.
  // Preserve the original operands for RVFI at the launch edge.
  always_ff @(posedge clock) begin
    if (mul_start || div_start) begin
      issued_rs1_q <= rs1;
      issued_rs2_q <= rs2;
    end
  end

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_taken;
  logic        actual_taken, indirect_taken;
  logic [29:0] direct_word_target;
  logic [31:0] resolved_pc;
  logic [3:0]  equal_group, less_group;
  logic        unsigned_less, ordered_less, equal_operands;

  for (genvar group = 0; group < 4; group++) begin : gen_compare
    assign equal_group[group] = rs1[group*8+:8] == rs2[group*8+:8];
    assign less_group[group]  = rs1[group*8+:8] <  rs2[group*8+:8];
  end
  assign unsigned_less = less_group[3]
                      || (equal_group[3] && less_group[2])
                      || ((&equal_group[3:2]) && less_group[1])
                      || ((&equal_group[3:1]) && less_group[0]);
  assign ordered_less = unsigned_less ^ ((rs1[31] ^ rs2[31]) && !in.ctrl.branch_op[1]);

  logic [31:0] other_operand;
  logic [3:0] byte_equal;
  logic [1:0] half_equal;
  logic byte_extension, half_extension, response_equal, use_load_compare;
  logic other_from_wb, other_from_rs1, other_from_rs2;

  // The intervening load owns EX/MEM. The unaliased source comes from
  // MEM/WB or ID's saved operand, so it needs only this forwarding mux.
  assign other_from_wb = in.load_rs1 ? in.rs2_sel[1] : in.rs1_sel[1];
  assign other_from_rs1 = !in.load_rs1 && in.rs1_sel[0];
  assign other_from_rs2 = in.load_rs1 && in.rs2_sel[0];
  assign other_operand = ({32{other_from_wb}} & fwd_mem_wb)
                       | ({32{other_from_rs1}} & in.rs1_val)
                       | ({32{other_from_rs2}} & in.rs2_val);
  for (genvar lane = 0; lane < 4; lane++) begin : gen_byte_equal
    assign byte_equal[lane] = raw_load[lane*8+:8] == other_operand[7:0];
  end
  for (genvar lane = 0; lane < 2; lane++) begin : gen_half_equal
    assign half_equal[lane] = raw_load[lane*16+:16] == other_operand[15:0];
  end
  // Lane equality already checks the sign bit. Check the upper bits of
  // the other operand before selecting the returned lane.
  assign byte_extension = (load_response.sign_extend && other_operand[7])
                        ? (&other_operand[31:8]) : !(|other_operand[31:8]);
  assign half_extension = (load_response.sign_extend && other_operand[15])
                        ? (&other_operand[31:16]) : !(|other_operand[31:16]);
  assign response_equal = (in.load_rs1 && in.load_rs2)
                       || (load_response.width == 2'd0 && byte_extension && byte_equal[load_response.lane])
                       || (load_response.width == 2'd1 && half_extension && half_equal[load_response.lane[1]])
                       || (load_response.width == 2'd2 && half_equal[0] &&
                           raw_load[31:16] == other_operand[31:16]);
  assign use_load_compare = in.load_compare && load_response.valid;
  assign equal_operands = use_load_compare ? response_equal : (&equal_group);
  // Legal branch funct3 selects equality or order with bit 2. Bit 0
  // inverts the test for BNE and the greater-than-or-equal branches.
  assign branch_taken = (in.ctrl.branch_op[2] ? ordered_less : equal_operands) ^ in.ctrl.branch_op[0];
  assign sequential_pc  = in.pc + 32'd4;
  assign direct_word_target = in.pc[31:2] + {{11{in.direct_offset[20]}}, in.direct_offset[20:2]};
  assign direct_target  = {direct_word_target, in.direct_offset[1], 1'b0};

  // ── Misaligned branch / jump target trap ──────────────────────────────
  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, suppress the redirect (PC stays linear), and clear
  // reg_write so JAL/JALR don't write the return address on trap.
  logic target_misaligned, misalign_fault;
  ctrl_t ctrl_with_trap;

  // The PC is word aligned, so the displacement gives direct target bit 1.
  assign target_misaligned = in.ctrl.is_jalr ? jalr_addr_low[1] : in.direct_offset[1];
  assign misalign_fault = in.ctrl.is_jump && target_misaligned;

  // ID waits for a load's MEM result and for any busy arithmetic in EX.
  // Among EX writers, only a link can lose write eligibility here.
  assign write_eligible = valid && in.ctrl.reg_write && !in.ctrl.mem_read
                        && !(in.ctrl.is_jump && target_misaligned);

  always_comb begin
    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;
  logic transfer_valid, advance;
  logic use_alu_result;

  // The low multiply reaches its EX/MEM register through the final mux.
  // Decode makes the remaining result sources mutually exclusive.
  assign use_alu_result = !(in.ctrl.is_jump || mul_high_instr || div_instr);

  assign transfer_valid = valid && !arithmetic_wait;
  assign advance = transfer_valid && !stall && !reset;

  // A taken prediction already followed the direct target. JALR always
  // corrects a taken transfer, and a boundary word always resumes fetch.
  assign direct_taken    = in.ctrl.is_jump && !in.ctrl.is_jalr
                         && !in.ctrl.is_illegal && !in.direct_offset[1];
  assign indirect_taken  = in.ctrl.is_jalr && !in.ctrl.is_illegal && !jalr_addr_low[1];
  assign actual_taken    = direct_taken || indirect_taken;
  assign recover_indirect = advance && indirect_taken;
  assign fence_i         = advance && in.instr[6:0] == 7'b0001111 && in.instr[14:12] == 3'b001;
  assign redirect        = fence_i || recover_indirect
                        || (advance && !in.ctrl.is_branch &&
                            (in.last_mapped_word || (in.predicted_taken != direct_taken)));
  assign resolved_pc     = ({32{!actual_taken}}   & sequential_pc)
                         | ({32{direct_taken}}   & direct_target)
                         | ({32{indirect_taken}} & {ordinary_addr[31:1], 1'b0});

  logic branch_advance, fix_sequential, fix_direct;
  assign branch_advance = advance && in.ctrl.is_branch;
  assign fix_sequential = in.last_mapped_word || in.predicted_taken;
  assign fix_direct = in.last_mapped_word || !in.predicted_taken;
  always_ff @(posedge clock) begin
    branch.taken                 <= branch_taken;
    branch.direct_if_taken       <= branch_advance && !in.direct_offset[1] && fix_direct;
    branch.sequential_if_taken   <= branch_advance && in.direct_offset[1] && fix_sequential;
    branch.sequential_if_untaken <= branch_advance && fix_sequential;
    branch.train_if_taken        <= branch_advance && !in.direct_offset[1];
    branch.train_if_untaken      <= branch_advance;
  end
  assign train_index = in.direction_index;
  assign train_negative = in.direct_offset[20];

  logic use_response;
  logic [31:0] retire_rs1, retire_rs2;
  assign use_response = use_load_compare || use_load_addr;
  assign retire_rs1 = (use_response && in.load_rs1) ? load_response.value : rs1;
  assign retire_rs2 = (use_response && in.load_rs2) ? load_response.value : rs2;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else begin
      reg_q.pc            <= in.pc;
      reg_q.alu_result    <= mul_low_instr ? mul_low_result
                           : (({32{in.ctrl.is_jump}} & sequential_pc)
                           |  ({32{mul_high_instr}}  & mul_high_result)
                           |  ({32{div_instr}}       & div_result)
                           |  ({32{use_alu_result}}  & alu_result));
      reg_q.effective_addr <= effective_addr;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= (mul_high_instr || div_instr) ? issued_rs1_q : retire_rs1;
      reg_q.rs2_val       <= (mul_high_instr || div_instr) ? issued_rs2_q : retire_rs2;
      // MEM selects a conditional successor from the registered predicate.
      reg_q.pc_next       <= resolved_pc;
      reg_q.branch_target <= direct_target;
      // Bubbles have no memory or register-write controls downstream.
      reg_q.ctrl          <= transfer_valid ? ctrl_with_trap : '0;
      reg_q.instr         <= in.instr;
      reg_q.is_divide     <= div_instr;
      reg_q.valid         <= transfer_valid;
    end
  end

  assign out = reg_q;

endmodule
