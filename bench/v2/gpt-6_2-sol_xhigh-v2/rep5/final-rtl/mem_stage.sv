// rtl/mem_stage.sv
//
// Memory access stage. Drives the dmem read/write ports combinationally
// from the EX/MEM register, and selects the result for MEM/WB.
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
//                 mem_wdata, plus the final rd_wdata.
module mem_stage (
  input  logic               clock,
  input  logic               reset,
  // hold_wb: retain the MEM/WB payload for the held EX operands.
  // Clear retirement valid so:
  //   - rvfi_order doesn't increment for held cycles
  //   - wb_stage doesn't write the regfile twice
  // Held ID/EX operands can still need that writeback value when the
  // stall ends.
  input  logic               hold_wb,
  input  logic               recovery,
  input  ex_mem_t  in,
  input  logic [31:0]        multiply_result,
  input  logic [31:0]        divide_result,
  // dmem interface
  output logic [31:0]        dmem_addr,
  output logic [31:0]        dmem_wdata,
  input  logic [31:0]        dmem_rdata,
  output logic [3:0]         dmem_wen,
  output logic               dmem_ren,
  output logic               next_write,  // eligible result for incoming ID
  output logic               redirect,
  output logic [31:2]        redirect_word,
  output logic               train_branch,
  output logic [5:0]         train_index,
  output logic               train_taken,
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
  logic [31:0] load_data;

  // EX has qualified the memory controls and register write with alignment.
  ctrl_t ctrl_with_trap;
  assign next_write = in.valid && in.ctrl.reg_write;

  always_comb begin
    // Byte/halfword replication for stores.
    case (in.ctrl.mem_width)
      2'd0:    wdata_rep = {4{in.write_data[7:0]}};
      2'd1:    wdata_rep = {2{in.write_data[15:0]}};
      default: wdata_rep = in.write_data;
    endcase

    // Byte-lane mask shifted to addr[1:0] * 1.
    case (in.ctrl.mem_width)
      2'd0:    byte_mask = (4'b0001 << in.mem_addr[1:0]);
      2'd1:    byte_mask = (4'b0011 << in.mem_addr[1:0]);
      default: byte_mask = 4'b1111;
    endcase

    dmem_addr  = in.mem_addr;
    dmem_wdata = wdata_rep;
    dmem_wen   = (in.valid && in.ctrl.mem_write) ? byte_mask : 4'b0000;
    dmem_ren   = in.valid && in.ctrl.mem_read;

    // Load extraction: shift right then sign/zero-extend the low N bits.
    shifted   = dmem_rdata >> (in.mem_addr[1:0] * 8);
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
    aligned_addr = (dmem_ren || |dmem_wen)
                 ? {in.mem_addr[31:2], 2'b00}
                 : 32'b0;
  end

  // ── MEM/WB register ───────────────────────────────────────────────────
  mem_wb_t reg_q;

  // The preceding producer's result has already crossed MEM/WB. EX
  // captured the ordinary operands too, for traps and encoded-only reads.
  logic [31:0] wb_result, late_sum, branch_next;
  logic late_equal, branch_fault, resolved_taken;

  assign late_sum = reg_q.result + in.late_operand;
  assign late_equal = (in.pending_rs1 && in.pending_rs2) ||
                      reg_q.result == in.late_operand;
  assign train_branch = in.valid && in.late_branch;
  assign train_index = in.prediction_index;
  assign train_taken = (in.pending_rs1 || in.pending_rs2)
                     ? late_equal ^ in.ctrl.branch_op[0] : in.branch_cond;
  assign branch_fault = train_taken && in.branch_target[1];
  assign resolved_taken = train_taken && !in.branch_target[1];
  assign branch_next = resolved_taken ? in.branch_target : in.pc_plus_4;
  assign redirect = train_branch && (resolved_taken != in.predicted_taken);
  assign redirect_word = in.recovery_word;

  always_comb begin
    ctrl_with_trap = in.ctrl;
    if (in.late_branch)
      ctrl_with_trap.is_illegal = branch_fault;
  end

  assign wb_result = ({32{in.writeback_select.alu}} & in.alu_result)
                   | ({32{in.writeback_select.load}} & load_data)
                   | ({32{in.writeback_select.mul}} & multiply_result)
                   | ({32{in.writeback_select.div}} & divide_result)
                   | ({32{in.writeback_select.late_add}} & late_sum)
                   | ({32{in.writeback_select.late_double}} & {reg_q.result[30:0], 1'b0});

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (recovery) begin
      // The wrong-path MEM entry is masked. Retire the saved branch now,
      // preserving the EX-recovery retirement gap for a DIV at the target.
      reg_q.valid <= 1'b1;
    end else if (hold_wb) begin
      // Clear retirement valid and leave the selected MEM/WB value
      // available to held EX operands.
      reg_q.valid <= 1'b0;
    end else begin
      reg_q.pc         <= in.pc;
      reg_q.result     <= wb_result;
      reg_q.rd         <= in.rd;
      reg_q.rs1_addr   <= in.rs1_addr;
      reg_q.rs2_addr   <= in.rs2_addr;
      reg_q.rs1_val    <= in.pending_rs1 ? reg_q.result : in.rs1_val;
      reg_q.rs2_val    <= in.pending_rs2 ? reg_q.result : in.rs2_val;
      reg_q.pc_next    <= in.late_branch ? branch_next : in.pc_next;
      reg_q.mem_addr   <= aligned_addr;
      reg_q.mem_rdata  <= dmem_rdata;
      reg_q.mem_wdata  <= wdata_rep;
      reg_q.mem_wmask  <= dmem_wen;
      reg_q.mem_rmask  <= dmem_ren ? byte_mask : 4'b0000;
      reg_q.ctrl       <= ctrl_with_trap;
      reg_q.instr      <= in.instr;
      reg_q.valid      <= in.valid && !redirect;
    end
  end

  assign out = reg_q;

endmodule
