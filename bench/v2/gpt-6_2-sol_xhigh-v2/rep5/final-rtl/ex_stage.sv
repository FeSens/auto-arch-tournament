// rtl/ex_stage.sv
//
// Execute stage. Selects operands, runs the ALU and address adder, and
// resolves branches. Owns the EX/MEM pipeline register.
//
// Latency:        1 cycle, or launch + initialization + seven work cycles for DIV/REM.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  logic               mem_recovery,  // cancel speculative divide work
  input  id_ex_t   in,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // MEM/WB registered result
  input  logic               mem_next_write,
  output ex_mem_t  out,
  output logic               fast_write,   // eligible fast result for incoming ID
  output logic [31:0]        multiply_result,
  output logic [31:0]        divide_result,
  output logic               divide_wait,  // hold issue and ID/EX until result is ready
  output logic               advance_aperture,
  output logic               redirect,
  output logic [31:2]        redirect_word,
  output logic               train_branch,
  output logic [5:0]         train_index,
  output logic               train_taken
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  assign rs1 = ({32{in.rs1_sel.ex_mem}}   & fwd_ex_mem)
             | ({32{in.rs1_sel.mem_wb}}   & fwd_mem_wb)
             | ({32{in.rs1_sel.reg_file}} & in.rs1_val);
  assign rs2 = ({32{in.rs2_sel.ex_mem}}   & fwd_ex_mem)
             | ({32{in.rs2_sel.mem_wb}}   & fwd_mem_wb)
             | ({32{in.rs2_sel.reg_file}} & in.rs2_val);

  // ── Load/store effective address ─────────────────────────────────────
  // The offset contributes 0 or -1 to the upper word before carry.
  // Compute the upper increment and decrement prefixes in parallel
  // with the low 12-bit sum.
  logic [12:0] addr_lo;
  logic [19:0] addr_hi;
  logic addr_carry, addr_borrow;

  assign addr_lo     = {1'b0, rs1[11:0]} + {1'b0, in.imm[11:0]};
  assign addr_carry  = addr_lo[12] && !in.imm[11];
  assign addr_borrow = !addr_lo[12] && in.imm[11];
  assign addr_hi[0]  = rs1[12] ^ addr_lo[12] ^ in.imm[11];
  for (genvar i = 1; i < 20; i++) begin : gen_address_hi
    assign addr_hi[i] = rs1[i+12] ^ ((addr_carry && (&rs1[12 +: i])) ||
                                     (addr_borrow && !(|rs1[12 +: i])));
  end

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_b;
  assign alu_b = in.ctrl.alu_src ? in.imm : rs2;

  logic [31:0] alu_result;
  alu #(.REGISTERED_SELECT(1'b1)) u_alu (
    .op  (5'b0),
    .selects (in.alu_select),
    .a   (rs1),
    .b   (alu_b),
    .out (alu_result)
  );

  // ── RV32M ────────────────────────────────────────────────────────────
  logic advance;
  logic is_divide, divide_idle, divide_launch, divide_ready;
  logic [31:0] divide_rs1_q, divide_rs2_q;

  multiplier u_multiplier (
    .clock   (clock),
    .reset   (reset),
    .capture (advance && in.ctrl.is_mul),
    .op      (in.ctrl.alu_op),
    .a       (rs1),
    .b       (rs2),
    .result  (multiply_result)
  );

  assign is_divide     = in.valid && in.ctrl.is_div;
  assign divide_launch = is_divide && divide_idle && !stall;
  assign divide_wait   = is_divide && !divide_ready;

  divider u_divider (
    .clock         (clock),
    .reset         (reset || mem_recovery),
    .launch        (divide_launch),
    .accept        (advance && in.ctrl.is_div),
    .op            (in.ctrl.alu_op),
    .a             (rs1),
    .b             (rs2),
    .idle          (divide_idle),
    .handoff_ready (divide_ready),
    .result        (divide_result)
  );

  // The forwarding sources can drain while the divide holds ID/EX.
  always_ff @(posedge clock) begin
    if (reset) begin
      divide_rs1_q <= '0;
      divide_rs2_q <= '0;
    end else if (divide_launch) begin
      divide_rs1_q <= rs1;
      divide_rs2_q <= rs2;
    end
  end

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic [3:0]  byte_equal, byte_less;
  logic        equal, unsigned_less, signed_less;
  logic        transfer_taken, resolved_taken;
  logic [31:0] target, pc_plus_4, pc_next;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] jalr_sum;  // bit 0 deliberately dropped per RV JALR spec
  /* verilator lint_on UNUSEDSIGNAL */

  for (genvar i = 0; i < 4; i++) begin : gen_branch_compare
    assign byte_equal[i] = rs1[i*8 +: 8] == rs2[i*8 +: 8];
    assign byte_less[i]  = rs1[i*8 +: 8] <  rs2[i*8 +: 8];
  end
  assign equal = &byte_equal;
  assign unsigned_less = byte_less[3]
                       || (byte_equal[3] && byte_less[2])
                       || (&byte_equal[3:2] && byte_less[1])
                       || (&byte_equal[3:1] && byte_less[0]);
  assign signed_less = rs1[31] == rs2[31] ? unsigned_less : rs1[31];

  // Decode admits only the equality and less-than branch pairs.
  assign branch_cond = in.ctrl.branch_op[0] ^
                      (in.ctrl.branch_op[2]
                       ? (in.ctrl.branch_op[1] ? unsigned_less : signed_less)
                       : equal);

  assign jalr_sum = rs1 + in.imm;
  assign target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0} : in.direct_target;
  assign transfer_taken = (in.ctrl.is_branch && branch_cond) || in.ctrl.is_jump;

  // ── Misaligned branch / jump target trap ──────────────────────────────
  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, suppress the redirect (PC stays linear), and clear
  // reg_write so JAL/JALR don't write the return address on trap.
  logic target_fault, memory_fault;
  ctrl_t ctrl_with_trap;

  assign target_fault = transfer_taken && target[1];
  assign memory_fault = (in.ctrl.mem_read || in.ctrl.mem_write) &&
                        ((in.ctrl.mem_width == 2'd2 && |addr_lo[1:0]) ||
                         (in.ctrl.mem_width == 2'd1 && addr_lo[0]));

  always_comb begin
    ctrl_with_trap = in.ctrl;
    ctrl_with_trap.is_illegal = in.ctrl.is_illegal || target_fault || memory_fault;
    ctrl_with_trap.reg_write = in.ctrl.reg_write && !memory_fault &&
                               !(in.ctrl.is_jump && target[1]);
    ctrl_with_trap.mem_read = in.ctrl.mem_read && !memory_fault;
    ctrl_with_trap.mem_write = in.ctrl.mem_write && !memory_fault;
  end

  assign pc_plus_4      = in.pc + 32'd4;
  assign resolved_taken = transfer_taken && !target[1];
  assign pc_next        = resolved_taken ? target : pc_plus_4;
  assign advance        = in.valid && !stall && !divide_wait;
  assign advance_aperture = advance && in.holds_fetch;
  // IF and EX use the same direct target. JALR was fetched sequentially.
  assign redirect       = advance && !in.late_branch && (resolved_taken != in.predicted_taken);
  // When the prediction misses, its opposite path is the successor.
  // Select that address independently of the branch condition.
  assign redirect_word  = in.predicted_taken ? pc_plus_4[31:2] : target[31:2];
  assign train_branch   = advance && in.ctrl.is_branch && !in.late_branch;
  assign train_index    = in.prediction_index;
  // Train on the branch condition, including when the target traps.
  assign train_taken    = branch_cond;

  logic [31:0] ex_result, late_operand, auipc_result;
  logic use_late_add, double_operand;
  assign auipc_result = {in.pc[31:12] + in.imm[31:12], in.pc[11:0]};
  assign ex_result = alu_result
                   | ({32{in.ctrl.is_jump}} & pc_plus_4)
                   | ({32{in.ctrl.is_auipc}} & auipc_result);
  // For one match, save the other operand. When both match, MEM doubles
  // the producer (or treats the branch operands as equal).
  assign late_operand = in.pending_rs1 ? alu_b : rs1;
  assign use_late_add = in.late_add && mem_next_write;
  assign double_operand = in.pending_rs1 && in.pending_rs2 && !in.ctrl.alu_src;
  // Decode asserts reg_write only for legal writers. A misaligned jump
  // must also suppress the fast link bypass.
  assign fast_write = in.valid && in.ctrl.reg_write && !(in.ctrl.is_jump && target[1]) &&
                      !(in.ctrl.mem_read || in.ctrl.is_mul || in.ctrl.is_div || in.late_add);

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
      reg_q.alu_result    <= ex_result;
      reg_q.mem_addr      <= {addr_hi, addr_lo[11:0]};
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= is_divide ? divide_rs1_q : rs1;
      reg_q.rs2_val       <= is_divide ? divide_rs2_q : rs2;
      reg_q.pc_next       <= pc_next;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.writeback_select.alu <= ctrl_with_trap.reg_write &&
                                    !(in.ctrl.mem_read || in.ctrl.is_mul || in.ctrl.is_div ||
                                      use_late_add);
      reg_q.writeback_select.load <= ctrl_with_trap.mem_read;
      reg_q.writeback_select.mul <= in.ctrl.is_mul;
      reg_q.writeback_select.div <= in.ctrl.is_div;
      reg_q.writeback_select.late_add <= use_late_add && !double_operand;
      reg_q.writeback_select.late_double <= use_late_add && double_operand;
      reg_q.pending_rs1   <= in.pending_rs1 && mem_next_write;
      reg_q.pending_rs2   <= in.pending_rs2 && mem_next_write;
      reg_q.late_operand  <= late_operand;
      reg_q.late_branch   <= in.late_branch;
      reg_q.branch_cond   <= branch_cond;
      reg_q.predicted_taken <= in.predicted_taken;
      reg_q.prediction_index <= in.prediction_index;
      reg_q.branch_target <= target;
      reg_q.pc_plus_4     <= pc_plus_4;
      reg_q.recovery_word <= redirect_word;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid && !divide_wait;
    end
  end

  assign out = reg_q;

endmodule
