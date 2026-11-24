// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// ID/EX holds one-hot enables for the raw EX/MEM result lanes, the
// MEM/WB writeback word and a prequalified default for each operand.
//
// Latency:        1 cycle for ALU operations. Divide holds ID/EX until complete.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  input  logic [31:0]        fwd_mem_wb,    // selected MEM/WB writeback word
  input  logic               load_response,
  input  logic [31:0]        raw_response,
  input  logic [31:0]        load_data,
  input  logic [1:0]         response_equal,
  output logic [31:0]        response_other_operand,
  output ex_mem_t  out,
  output logic               write_eligible,
  output logic               divide_wait,
  output logic               repair,
  output pc_pair_t           repair_pc,
  output logic               fence_i,
  output logic               train_advance,
  output logic               train_direct,
  output logic               train_taken,
  output logic [31:0]        train_target
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  ex_mem_t reg_q;
  logic [31:0] rs1;
  logic [31:0] rs2;
  logic [31:0] alu_b;

  function automatic [31:0] forward_operand(
    input operand_sel_t sel,
    input logic [31:0] default_value
  );
    logic [31:0] add_sub, other_wb, mul;

    // Each pair uses four LUT inputs per bit. The three pair outputs
    // and the unmasked default fit a single LUT4 in the second level.
    add_sub  = ({32{sel.ex_mem.add}}      & reg_q.result.add)
             | ({32{sel.ex_mem.sub}}      & reg_q.result.sub);
    other_wb = ({32{sel.ex_mem.other}}    & reg_q.result.other)
             | ({32{sel.mem_wb}}          & fwd_mem_wb);
    mul      = ({32{sel.ex_mem.mul_low}}  & reg_q.result.product[31:0])
             | ({32{sel.ex_mem.mul_high}} & reg_q.result.product[63:32]);
    forward_operand = default_value | add_sub | other_wb | mul;
  endfunction

  assign rs1   = forward_operand(in.rs1_sel, in.rs1_default);
  assign rs2   = forward_operand(in.rs2_sel, in.rs2_default);
  assign alu_b = forward_operand(in.alu_b_sel, in.alu_b_default);

  logic [31:0] add_result, sub_result, other_result, unused_alu_result;
  alu u_alu (
    .op           (in.ctrl.alu_op),
    .a            (rs1),
    .b            (alu_b),
    .out          (unused_alu_result),
    .add_result   (add_result),
    .sub_result   (sub_result),
    .other_result (other_result)
  );

  logic [63:0] product;

`ifdef RISCV_FORMAL_ALTOPS
  // Match the riscv-formal substitutes, with the same register boundary
  // and forwarding selection as the hardware product.
  logic [31:0] alt_product_word;
  always_comb begin
    case (in.ctrl.alu_op)
      ALU_MUL:    alt_product_word = (rs1 + rs2) ^ 32'h5876063e;
      ALU_MULH:   alt_product_word = (rs1 + rs2) ^ 32'hf6583fb7;
      ALU_MULHU:  alt_product_word = (rs1 + rs2) ^ 32'h949ce5e8;
      ALU_MULHSU: alt_product_word = (rs1 - rs2) ^ 32'hecfbe137;
      default:    alt_product_word = 32'b0;
    endcase
  end
  assign product = {2{alt_product_word}};
`else
  logic signed [32:0] mul_a, mul_b;
  assign mul_a = $signed({rs1[31] && (in.ctrl.alu_op == ALU_MULH ||
                                     in.ctrl.alu_op == ALU_MULHSU), rs1});
  assign mul_b = $signed({rs2[31] && (in.ctrl.alu_op == ALU_MULH), rs2});
  assign product = mul_a * mul_b;
`endif

  logic divide;
  logic div_issue_ready, div_result_valid;
  logic [31:0] div_result, div_src_a, div_src_b;

  assign divide = in.valid && !repair && in.divide;
  assign divide_wait = divide && !div_result_valid;

  logic ex_valid;
  assign ex_valid = in.valid && !divide_wait && !repair;

  // The divider captures the forwarded operands on issue, before older
  // stages drain, and supplies those sources for RVFI when it completes.
  div_unit u_div (
    .clock        (clock),
    .reset        (reset),
    .issue        (divide && div_issue_ready && !stall),
    .issue_ready  (div_issue_ready),
    .op           (in.ctrl.alu_op),
    .a            (rs1),
    .b            (rs2),
    .result_valid (div_result_valid),
    .result_ready (divide && !stall),
    .result       (div_result),
    .src_a        (div_src_a),
    .src_b        (div_src_b)
  );

  // ── Memory request ────────────────────────────────────────────────────
  logic [31:0] effective_addr, response_addr;
  logic carry_one, carry_two, use_load_response, use_branch_response;
  logic [1:0] response_sources;

  assign effective_addr = rs1 + in.imm;
  assign use_load_response = in.load_pair && load_response;
  assign use_branch_response = in.branch_pair && load_response;
  assign response_sources = in.response_match & {2{use_load_response || use_branch_response}};
  // ID admits a paired branch only if its independent operand needs no
  // EX/MEM or MEM/WB bypass. The ordinary operands still cover a trap.
  assign response_other_operand = in.response_match[0] ? in.rs2_default : in.rs1_default;

  // Offsets 0, 1 and 2 can generate a carry only in the low two bits.
  // Higher sums use parallel reductions of the raw response prefixes.
  assign carry_one = raw_response[0] && in.imm[0];
  assign carry_two = raw_response[1] && (in.imm[1] || carry_one);
  assign response_addr[0] = raw_response[0] ^ in.imm[0];
  assign response_addr[1] = raw_response[1] ^ in.imm[1] ^ carry_one;
  assign response_addr[2] = raw_response[2] ^ carry_two;
  for (genvar bit_idx = 3; bit_idx < 32; bit_idx++) begin : gen_response_addr
    assign response_addr[bit_idx] = raw_response[bit_idx]
                                  ^ (carry_two && (&raw_response[bit_idx-1:2]));
  end

  // ── Control flow ──────────────────────────────────────────────────────
  logic [3:0]  byte_equal, byte_less;
  logic        high_less, low_less, ordered_branch;
  logic [1:0]  compare_groups, compare_q;
  logic        both_set;
  logic        is_jal, is_direct, jalr_taken, fence_i_resolved;
  logic        jalr_misaligned, jump_misaligned;
  logic        direct_if_both, direct_if_either_clear;
  logic        direct_if_both_q, direct_if_either_clear_q;
  logic        direct_taken, direct_misaligned_q, is_direct_q, jalr_taken_q;
  logic        repair_direct, repair_always, repair_if_both_q, repair_if_either_clear_q;
  logic        fence_i_q;
  logic        trained_on_repair_q;
  pc_pair_t    direct_pc, fallthrough_pc, repair_pc_q;
  logic [31:2] direct_target_q;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] jalr_successor;
  /* verilator lint_on UNUSEDSIGNAL */
  ctrl_t       ctrl_with_trap;

  for (genvar i = 0; i < 4; i++) begin : gen_branch_compare
    assign byte_equal[i] = rs1[8*i +: 8] == rs2[8*i +: 8];
    assign byte_less[i]  = rs1[8*i +: 8] <  rs2[8*i +: 8];
  end

  assign high_less = (byte_less[3] ^ (in.branch_sel.signed_compare && (rs1[31] != rs2[31])))
                   | (byte_equal[3] & byte_less[2]);
  assign low_less = byte_less[1] | (byte_equal[1] & byte_less[0]);
  assign ordered_branch = in.branch_sel.lt || in.branch_sel.ge;

  // Both groups are set for equality or, for ordered branches, if the
  // high half is less or the high halves tie and the low half is less.
  assign compare_groups = use_branch_response
                        ? response_equal | {2{&in.response_match}}
                        : ordered_branch ? {high_less || (&byte_equal[3:2]), high_less || low_less}
                                         : {&byte_equal[3:2], &byte_equal[1:0]};

  assign direct_pc.addr = in.pc.addr + in.imm[31:2];
  // Subtracting the complemented displacement adds it with a carry-in
  // of one, giving the successor in a parallel word-address sum.
  assign direct_pc.addr_plus_four = in.pc.addr - ~in.imm[31:2];
  assign fallthrough_pc.addr = in.pc.addr_plus_four;
  assign fallthrough_pc.addr_plus_four = in.pc.addr_plus_four + 30'd1;
  assign jalr_successor = rs1 + {{19{in.jalr_imm_plus_four[12]}}, in.jalr_imm_plus_four};
  // The fetch PC is word aligned. Direct targets inherit immediate bit 1.
  // JALR clears bit 0, so only bit 1 of the sum (including carry) matters.
  assign jalr_misaligned = rs1[1] ^ in.imm[1] ^ (rs1[0] & in.imm[0]);
  assign is_jal = in.ctrl.is_jump && !in.ctrl.is_jalr;
  assign direct_if_both = is_jal || in.branch_sel.eq || in.branch_sel.lt;
  assign direct_if_either_clear = is_jal || in.branch_sel.ne || in.branch_sel.ge;
  assign is_direct = direct_if_both || direct_if_either_clear;
  assign jalr_taken = in.ctrl.is_jalr && !jalr_misaligned;
  assign fence_i_resolved = in.instr[6:0] == 7'h0f && in.instr[14:12] == 3'b001;
  assign jump_misaligned = in.ctrl.is_jump && (in.ctrl.is_jalr ? jalr_misaligned : in.imm[1]);
  assign repair_direct = in.direct_target_differs;
  assign repair_always = jalr_taken || fence_i_resolved;

  // The repair cycle holds the resolver in EX/MEM while discarding
  // younger work. ID can forward its link through MEM/WB when the first
  // corrected word issues on the next edge.
  always_ff @(posedge clock) begin
    if (reset || repair) begin
      repair_if_both_q <= 1'b0;
      repair_if_either_clear_q <= 1'b0;
      fence_i_q <= 1'b0;
    end else if (!stall) begin
      repair_if_both_q <= ex_valid && (repair_always ||
                           (repair_direct && (in.predicted_taken ^ (direct_if_both && !in.imm[1]))));
      repair_if_either_clear_q <= ex_valid && (repair_always ||
                           (repair_direct && (in.predicted_taken ^ (direct_if_either_clear && !in.imm[1]))));
      fence_i_q <= ex_valid && fence_i_resolved;
    end

    if (!stall && !repair) begin
      if (in.ctrl.is_jalr)
        repair_pc_q <= {effective_addr[31:2], jalr_successor[31:2]};
      else if (fence_i_resolved || in.predicted_taken)
        repair_pc_q <= fallthrough_pc;
      else
        repair_pc_q <= direct_pc;

      compare_q <= compare_groups;
      direct_if_both_q <= direct_if_both;
      direct_if_either_clear_q <= direct_if_either_clear;
      direct_misaligned_q <= in.imm[1];
      is_direct_q <= is_direct;
      jalr_taken_q <= jalr_taken;
      direct_target_q <= direct_pc.addr;
    end
  end

  assign both_set = &compare_q;
  assign repair = (both_set && repair_if_both_q) || (!both_set && repair_if_either_clear_q);
  assign repair_pc = repair_pc_q;
  assign fence_i = fence_i_q;
  assign direct_taken = (both_set && direct_if_both_q) || (!both_set && direct_if_either_clear_q);

  // ID uses this with the current EX destination on the advancing edge.
  // Loads become eligible in MEM after the load-use interlock.
  assign write_eligible = ex_valid && ctrl_with_trap.reg_write && !in.ctrl.mem_read;

  always_comb begin
    ctrl_with_trap = in.ctrl;
    ctrl_with_trap.is_illegal = in.ctrl.is_illegal || jump_misaligned;
    ctrl_with_trap.reg_write = in.ctrl.reg_write && !jump_misaligned;
  end

  // ── EX/MEM register ───────────────────────────────────────────────────
  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (!stall && !repair) begin
      reg_q.pc            <= {in.pc.addr, 2'b00};
      reg_q.result.add    <= add_result;
      reg_q.result.sub    <= sub_result;
      // Jumps, AUIPC and divides have no base ALU other result.
      reg_q.result.other  <= other_result
                           | ({32{in.ctrl.is_auipc}} & {direct_pc.addr, 2'b00})
                           | ({32{in.ctrl.is_jump}}  & {in.pc.addr_plus_four, 2'b00})
                           | ({32{divide}}           & div_result);
      reg_q.result.product <= product;
      reg_q.result_sel    <= in.result_sel;
      reg_q.mem_addr      <= use_load_response ? response_addr : effective_addr;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= response_sources[0] ? load_data : divide ? div_src_a : rs1;
      reg_q.rs2_val       <= response_sources[1] ? load_data : divide ? div_src_b : rs2;
      reg_q.pc_next       <= {in.pc.addr_plus_four, 2'b00};
      // Bubbles have no forwarding, writeback, or memory side effects.
      reg_q.ctrl          <= ex_valid ? ctrl_with_trap : '0;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= ex_valid;
    end
  end

  always_comb begin
    out = reg_q;
    if (train_taken) out.pc_next = train_target;
    if (jalr_taken_q) out.pc_next = {repair_pc_q.addr, 2'b00};
    out.ctrl.is_illegal = reg_q.ctrl.is_illegal || (direct_taken && direct_misaligned_q);
  end
  assign train_direct = reg_q.valid && is_direct_q && !out.ctrl.is_illegal;
  assign train_taken = direct_taken && !direct_misaligned_q;
  assign train_target = {direct_target_q, 2'b00};

  // A resolver is accepted for replay training on its first ready
  // cycle. The following cycle still owns the same EX/MEM entry when
  // a repair held it, so skip that repeated observation.
  always_ff @(posedge clock) begin
    trained_on_repair_q <= !reset && repair;
  end
  assign train_advance = reg_q.valid && !stall && !trained_on_repair_q;

endmodule
