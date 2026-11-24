// rtl/mem_stage.sv
//
// Memory access stage. Drives dmem from the registered effective address
// and store data. Completes loads and RV32M results, then registers the
// selected writeback value in MEM/WB.
//
// Byte-lane discipline:
//   - Write data is replicated across all four byte lanes; the
//     byte-mask (mem_wmask) selects the actual destination bytes.
//   - Load: shift the raw word right by `addr[1:0]*8`, then sign- or
//     zero-extend the low 8/16 bits per the LB/LBU/LH/LHU encoding.
//   - For RVFI ALIGNED_MEM, mem_addr is reported word-aligned and the
//     byte position is captured in mem_rmask / mem_wmask.
//
// Latency:        1 cycle (MEM/WB register clocked here).
// RVFI fields:    feeds mem_addr, mem_rmask, mem_wmask, mem_rdata,
//                 mem_wdata, and rd_wdata via the selected result.
module mem_stage (
  input  logic               clock,
  input  logic               reset,
  // A data-bus hold preserves WB forwarding for the held EX instruction.
  // Clearing valid after the first cycle prevents another retirement.
  input  logic               hold_wb,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ex_mem_t  in,
  /* verilator lint_on UNUSEDSIGNAL */
  // dmem interface
  output logic [31:0]        dmem_addr,
  output logic [31:0]        dmem_wdata,
  input  logic [31:0]        dmem_rdata,
  output logic [3:0]         dmem_wen,
  output logic               dmem_ren,
  output logic               dmem_pending,
  output logic               wb_reg_write,
  output logic [31:0]        load_data,
  output logic               redirect,
  output predictor_update_t predictor_update,
  output replay_update_t     replay_update,
  // MEM/WB register output
  output mem_wb_t  out
);

  logic [31:0] wdata_rep;
  logic [3:0]  byte_mask;
  logic [31:0] aligned_addr;
  // shifted[31:16] is dropped on byte/halfword loads; only [15:0] feeds
  // the sign/zero-extension mux.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] shifted;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [7:0]  byte_val;
  logic [15:0] hword_val;

  // Misaligned mem-access trap. RV32I requires word-aligned LW/SW and
  // halfword-aligned LH/LHU/SH; byte ops are always aligned.
  // riscv-formal's RISCV_FORMAL_ALIGNED_MEM contract demands rvfi_trap=1
  // when the effective byte address is not aligned to the access width.
  // On trap, the dmem ports are gated off and MEM records the trap for WB.
  logic mem_misalign;
  logic mem_op;

  always_comb begin
    // Byte/halfword replication for stores.
    case (in.ctrl.mem_width)
      2'd0:    wdata_rep = {4{in.write_data[7:0]}};
      2'd1:    wdata_rep = {2{in.write_data[15:0]}};
      default: wdata_rep = in.write_data;
    endcase

    // Byte-lane mask shifted to addr[1:0] * 1.
    case (in.ctrl.mem_width)
      2'd0:    byte_mask = (4'b0001 << in.effective_addr[1:0]);
      2'd1:    byte_mask = (4'b0011 << in.effective_addr[1:0]);
      default: byte_mask = 4'b1111;
    endcase

    mem_op       = in.valid && (in.ctrl.mem_read || in.ctrl.mem_write);
    mem_misalign = mem_op && (
                     (in.ctrl.mem_width == 2'd2 && in.effective_addr[1:0] != 2'b00) ||
                     (in.ctrl.mem_width == 2'd1 && in.effective_addr[0]   != 1'b0)
                     // 2'd0 (byte) is never misaligned.
                   );

    // Load extraction: shift right then sign/zero-extend the low N bits.
    shifted   = dmem_rdata >> (in.effective_addr[1:0] * 8);
    byte_val  = shifted[7:0];
    hword_val = shifted[15:0];
    case (in.ctrl.mem_width)
      2'd0:    load_data = in.ctrl.mem_sext
                         ? {{24{byte_val[7]}},  byte_val}
                         : {24'b0,              byte_val};
      2'd1:    load_data = in.ctrl.mem_sext
                         ? {{16{hword_val[15]}}, hword_val}
                         : {16'b0,               hword_val};
      default: load_data = dmem_rdata;
    endcase

    // RVFI ALIGNED_MEM expects word-aligned mem_addr; mem_addr=0 if no access.
    aligned_addr = (mem_op && !mem_misalign)
                 ? {in.effective_addr[31:2], 2'b00}
                 : 32'b0;
  end

  assign dmem_pending = mem_op && !mem_misalign;
  assign dmem_addr    = in.effective_addr;
  assign dmem_wdata   = wdata_rep;
  assign dmem_wen     = (in.ctrl.mem_write && dmem_pending) ? byte_mask : 4'b0000;
  assign dmem_ren     = in.ctrl.mem_read && dmem_pending;
  // The lookahead select and the advancing WB payload share eligibility.
  assign wb_reg_write = in.valid && in.ctrl.reg_write && !mem_misalign;

  logic [31:0] mul_result, div_result, wb_result;
  mul_reduce u_mul_reduce (.products(in.mul_products), .result(mul_result));
  assign div_result = in.div_negate ? -in.div_magnitude : in.div_magnitude;

  always_comb begin
    case (in.result_kind)
      RESULT_LOAD: wb_result = load_data;
      RESULT_MUL:  wb_result = mul_result;
      RESULT_DIV:  wb_result = div_result;
      default:     wb_result = in.alu_result;
    endcase
  end

  // ── Deferred branch resolve ──────────────────────────────────────────
  late_branch_t late_branch;
  logic deferred_branch, late_equal, load_less_unsigned, load_less;
  logic late_less, late_taken, branch_taken;

  assign late_branch = in.late_branch;
  assign deferred_branch = late_branch.match.rs1 || late_branch.match.rs2;
  assign late_equal = (late_branch.match.rs1 && late_branch.match.rs2)
                   || (&late_branch.byte_equal);
  assign load_less_unsigned = late_branch.byte_less[3]
                           || (late_branch.byte_equal[3] && late_branch.byte_less[2])
                           || ((&late_branch.byte_equal[3:2]) && late_branch.byte_less[1])
                           || ((&late_branch.byte_equal[3:1]) && late_branch.byte_less[0]);
  assign load_less = !in.ctrl.branch_op[1] && (late_branch.load_sign ^ late_branch.other_sign)
                   ? late_branch.load_sign : load_less_unsigned;
  assign late_less = !late_equal && (load_less ^ late_branch.match.rs2);
  assign late_taken = (in.ctrl.branch_op[2] ? late_less : late_equal) ^ in.ctrl.branch_op[0];
  // A trapping load leaves the register file unchanged. EX computed the
  // fallback with the older values selected by ordinary forwarding.
  assign branch_taken = deferred_branch && late_branch.load_writes ? late_taken : in.branch_taken;
  assign redirect = in.valid && deferred_branch && (branch_taken ^ late_branch.predicted_taken);

  assign predictor_update.valid = in.valid && in.ctrl.is_branch && !in.ctrl.is_illegal;
  assign predictor_update.index = in.branch_index;
  assign predictor_update.taken = branch_taken;

  // Record the direct sum even when a conditional branch fell through.
  // An aligned target on the same page needs only its word offset in RAM.
  logic local_target;
  assign local_target = in.pc[31:12] == late_branch.target[31:12];

  // Train once on MEM completion, including a deferred miss that publishes
  // its saved retirement packet on the following cycle.
  always_ff @(posedge clock) begin
    replay_update.valid <= !reset && in.valid && !hold_wb
                        && !in.ctrl.is_illegal && !mem_misalign && !in.ctrl.is_jalr
                        && in.instr[6:0] != 7'b1110011 && in.instr[6:0] != 7'b0001111;
    replay_update.pc          <= in.pc[31:2];
    replay_update.instr       <= in.instr[31:2];
    replay_update.target_word <= late_branch.target[11:2];
    replay_update.branch      <= local_target && in.ctrl.is_branch && !in.instr[8];
    replay_update.jal         <= local_target && in.ctrl.is_jump && !in.instr[21];
  end

  // ── MEM/WB register ───────────────────────────────────────────────────
  mem_wb_t reg_q;
  logic publish_branch_q;

  always_ff @(posedge clock) begin
    if (reset) publish_branch_q <= 1'b0;
    else       publish_branch_q <= redirect;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (publish_branch_q) begin
      // A miss squashes the younger EX instruction, giving this saved
      // packet one empty slot to retire at the interlocked branch's edge.
      reg_q.valid <= 1'b1;
    end else if (hold_wb) begin
      reg_q.valid <= 1'b0;
    end else begin
      reg_q.pc         <= in.pc;
      reg_q.result     <= wb_result;
      reg_q.rd         <= in.rd;
      reg_q.rs1_addr   <= in.rs1_addr;
      reg_q.rs2_addr   <= in.rs2_addr;
      reg_q.rs1_val    <= late_branch.match.rs1 && late_branch.load_writes ? reg_q.result : in.rs1_val;
      reg_q.rs2_val    <= late_branch.match.rs2 && late_branch.load_writes ? reg_q.result : in.rs2_val;
      reg_q.pc_next    <= deferred_branch
                       ? {branch_taken ? late_branch.target : late_branch.fallthrough, 2'b00}
                       : in.pc_next;
      reg_q.mem_addr   <= aligned_addr;
      reg_q.mem_rdata  <= dmem_rdata;
      reg_q.mem_wdata  <= wdata_rep;
      reg_q.mem_wmask  <= dmem_wen;
      reg_q.mem_rmask  <= dmem_ren ? byte_mask : 4'b0000;
      reg_q.reg_write  <= wb_reg_write;
      reg_q.trap       <= in.ctrl.is_illegal || mem_misalign;
      reg_q.instr      <= in.instr;
      reg_q.valid      <= in.valid && !redirect;
    end
  end

  assign out = reg_q;

endmodule
