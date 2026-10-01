// rtl/ex_stage.sv
//
// Execute stage. Operands have already been forwarded and registered by
// operand_stage; this stage computes ALU results, addresses and redirects.
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t             in,
  output ex_mem_t  out,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               div_hold,
  output logic               producer_reg_write
);

  // The values in this payload are the forwarded register operands.
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
  alu u_alu (
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result)
  );

  // Loads and stores use a sign-extended 12-bit immediate. Keep their
  // address path separate from the general ALU: the low 12-bit sum emits
  // a carry, and the upper 20 bits only need to increment, decrement, or
  // hold according to that carry and the immediate sign.
  logic [12:0] mem_addr_low_sum;
  logic        mem_addr_inc_hi;
  logic        mem_addr_dec_hi;
  logic [19:0] mem_addr_hi;
  logic [31:0] mem_effective_addr;

  assign mem_addr_low_sum = {1'b0, rs1[11:0]} + {1'b0, in.imm[11:0]};
  assign mem_addr_inc_hi = mem_addr_low_sum[12] && !in.imm[11];
  assign mem_addr_dec_hi = !mem_addr_low_sum[12] && in.imm[11];

  assign mem_addr_hi[0] = rs1[12] ^ mem_addr_inc_hi ^ mem_addr_dec_hi;
  for (genvar addr_bit = 1; addr_bit < 20; addr_bit++) begin : gen_mem_addr_hi
    assign mem_addr_hi[addr_bit] = rs1[12 + addr_bit] ^
      ((mem_addr_inc_hi && (&rs1[12 +: addr_bit])) ||
       (mem_addr_dec_hi && (~|rs1[12 +: addr_bit])));
  end
  assign mem_effective_addr = {mem_addr_hi, mem_addr_low_sum[11:0]};

  // DIV/REM use one iterative unit.  Under ALTOPS, retain the formal
  // algebraic ALU substitutions and bypass the multi-cycle handshake.
  logic        is_div_op;
  logic        div_start;
  logic        div_busy;
  logic        div_done;
  logic        div_consume;
  logic [31:0] div_result;
  logic [31:0] div_rs1_q;
  logic [31:0] div_rs2_q;

  always_comb begin
`ifdef RISCV_FORMAL_ALTOPS
    is_div_op = 1'b0;
`else
    is_div_op = (in.ctrl.alu_op == ALU_DIV)  ||
                (in.ctrl.alu_op == ALU_DIVU) ||
                (in.ctrl.alu_op == ALU_REM)  ||
                (in.ctrl.alu_op == ALU_REMU);
`endif
    div_start   = is_div_op && !div_busy && !div_done;
    div_consume = is_div_op && div_done && !stall;
    div_hold    = is_div_op && !div_done;
  end

  div_unit u_div (
    .clock    (clock),
    .reset    (reset),
    .start    (div_start),
    .consume  (div_consume),
    .op       (in.ctrl.alu_op),
    .dividend (rs1),
    .divisor  (rs2),
    .busy     (div_busy),
    .done     (div_done),
    .result   (div_result)
  );

  // Preserve the values actually used to start division for RVFI and
  // downstream store-data metadata, even after forwarding sources drain.
  always_ff @(posedge clock) begin
    if (reset) begin
      div_rs1_q <= 32'd0;
      div_rs2_q <= 32'd0;
    end else if (div_start) begin
      div_rs1_q <= rs1;
      div_rs2_q <= rs2;
    end
  end

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken;
  logic        branch_mismatch;
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
    branch_mismatch = in.ctrl.is_branch &&
                      (branch_taken != in.predicted_taken);
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

  // Hazards must not wait for a result that this instruction will suppress
  // because its control-transfer target is misaligned.
  assign producer_reg_write = ctrl_with_trap.reg_write;

  assign redirect        = (branch_mismatch || in.ctrl.is_jump) && !misalign_fault;
  assign redirect_target = in.ctrl.is_jump ? jump_target
                         : branch_taken ? branch_target
                                        : (in.pc + 32'd4);

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (is_div_op && !div_done) begin
      // The older EX/MEM instruction drains on the first divide cycle; EX/MEM
      // receives bubbles while the divider works and upstream stages hold.
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // The memory port gets its own address register, so dmem timing is
      // isolated from the general ALU result used for writeback/forwarding.
      reg_q.mem_addr      <= mem_effective_addr;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= in.ctrl.is_jump ? (in.pc + 32'd4)
                                             : (is_div_op ? div_result : alu_result);
      reg_q.write_data    <= is_div_op ? div_rs2_q : rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= is_div_op ? div_rs1_q : rs1;
      reg_q.rs2_val       <= is_div_op ? div_rs2_q : rs2;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect.
      reg_q.pc_next       <= misalign_fault     ? (in.pc + 32'd4)
                            : in.ctrl.is_jump   ? jump_target
                            : branch_taken      ? branch_target
                                                : (in.pc + 32'd4);
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
