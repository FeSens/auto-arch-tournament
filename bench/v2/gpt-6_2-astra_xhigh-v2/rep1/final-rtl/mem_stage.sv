// rtl/mem_stage.sv
//
// Memory access stage. Drives the dmem read/write ports combinationally
// from the EX/MEM register. Loads and multiplies share the MEM/WB
// read_data field for the JALR target comparison. The general operand
// bypass and register file receive the selected result in wb_data.
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
//                 mem_wdata, plus rd_wdata for loads and multiplies.
module mem_stage (
  input  logic               clock,
  input  logic               reset,
  // A dmem wait clears valid while preserving the previous WB payload
  // for forwarding to the instruction held in EX.
  input  logic               hold_wb,
  input  logic               annul,
  output logic               late_taken,
  output logic               late_miss,
  output logic [31:2]        late_next_pc,
  // IF consumes the prediction-training fields of this same register.
  /* verilator lint_off UNUSEDSIGNAL */
  input  ex_mem_t  in,
  /* verilator lint_on UNUSEDSIGNAL */
  // dmem interface
  output logic [31:0]        dmem_addr,
  output logic [31:0]        dmem_wdata,
  input  logic [31:0]        dmem_rdata,
  output logic [3:0]         dmem_wen,
  output logic               dmem_ren,
  output logic               producer_writes,
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
  mem_wb_t reg_q;
  logic [31:0] store_data, late_sum;
  logic late_condition;
  assign store_data = in.late_rs2 ? reg_q.wb_data : in.write_data;
  assign late_sum = reg_q.wb_data + (in.both_late ? reg_q.wb_data : in.other_operand);
  assign late_condition = (in.both_late || reg_q.wb_data == in.other_operand)
                        ^ in.ctrl.branch_op[0];
  assign late_taken = late_condition && !in.branch_target[1];
  logic [31:0] fallthrough;
  assign fallthrough = in.pc + 32'd4;
  assign late_next_pc = late_taken ? in.branch_target[31:2] : fallthrough[31:2];
  assign late_miss = in.deferred_branch && !annul &&
                     (late_taken != in.predicted_taken ||
                      (late_taken && !in.prediction_matches));

  // Misaligned mem-access trap. RV32I requires word-aligned LW/SW and
  // halfword-aligned LH/LHU/SH; byte ops are always aligned.
  // riscv-formal's RISCV_FORMAL_ALIGNED_MEM contract demands rvfi_trap=1
  // when the effective byte address is not aligned to the access width.
  // On trap, the dmem ports are gated off and ctrl propagates is_illegal.
  logic mem_misalign;
  logic mem_op;
  ctrl_t ctrl_with_trap;

  always_comb begin
    // Byte/halfword replication for stores.
    case (in.ctrl.mem_width)
      2'd0:    wdata_rep = {4{store_data[7:0]}};
      2'd1:    wdata_rep = {2{store_data[15:0]}};
      default: wdata_rep = store_data;
    endcase

    // Byte-lane mask shifted to addr[1:0] * 1.
    case (in.ctrl.mem_width)
      2'd0:    byte_mask = (4'b0001 << in.mem_addr[1:0]);
      2'd1:    byte_mask = (4'b0011 << in.mem_addr[1:0]);
      default: byte_mask = 4'b1111;
    endcase

    mem_op       = in.ctrl.mem_read || in.ctrl.mem_write;
    mem_misalign = mem_op && (
                     (in.ctrl.mem_width == 2'd2 && in.mem_addr[1:0] != 2'b00) ||
                     (in.ctrl.mem_width == 2'd1 && in.mem_addr[0]   != 1'b0)
                     // 2'd0 (byte) is never misaligned.
                   );

    ctrl_with_trap = in.ctrl;
    if (mem_misalign || (in.deferred_branch && late_condition && in.branch_target[1])) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end

    // Combinational dmem outputs — gated off on misalign.
    dmem_addr  = in.mem_addr;
    dmem_wdata = wdata_rep;
    dmem_wen   = (in.ctrl.mem_write && !mem_misalign && !annul) ? byte_mask : 4'b0000;
    dmem_ren   = in.ctrl.mem_read && !mem_misalign && !annul;

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
    aligned_addr = (mem_op && !mem_misalign)
                 ? {in.mem_addr[31:2], 2'b00}
                 : 32'b0;
  end

  assign producer_writes = in.ctrl.reg_write && !mem_misalign && !annul;

  // ── MEM/WB register ───────────────────────────────────────────────────
  logic [31:0] mem_result;
  // A multiply requires both sources in EX, so other_operand holds rs1.
  assign mem_result = in.ctrl.mem_read ? load_data
                    : in.deferred_add ? late_sum
                    : multiply_result(in.ctrl.alu_op, {in.mul_lhs_negative, in.other_operand},
                                                       {in.mul_rhs_negative, in.rs2_val});

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (hold_wb) begin
      // Retire once and retain the WB forwarding source for held EX operands.
      reg_q.valid <= 1'b0;
    end else begin
      reg_q.pc         <= in.pc;
      reg_q.alu_result <= in.alu_result;
      reg_q.read_data  <= mem_result;
      reg_q.wb_data    <= in.ctrl.mem_to_reg ? mem_result : in.alu_result;
      reg_q.rd         <= in.rd;
      reg_q.rs1_addr   <= in.rs1_addr;
      reg_q.rs2_addr   <= in.rs2_addr;
      reg_q.rs1_val    <= in.late_rs1 ? reg_q.wb_data : in.rs1_val;
      reg_q.rs2_val    <= in.late_rs2 ? reg_q.wb_data : in.rs2_val;
      reg_q.pc_next    <= (in.deferred_branch ? late_taken : in.early_taken) ?
                           in.branch_target : fallthrough;
      reg_q.mem_addr   <= aligned_addr;
      reg_q.mem_rdata  <= dmem_rdata;
      reg_q.mem_wdata  <= wdata_rep;
      reg_q.mem_wmask  <= (in.ctrl.mem_write && !mem_misalign) ? byte_mask : 4'b0000;
      reg_q.mem_rmask  <= (in.ctrl.mem_read  && !mem_misalign) ? byte_mask : 4'b0000;
      reg_q.ctrl       <= ctrl_with_trap;
      reg_q.instr      <= in.instr;
      reg_q.valid      <= in.valid && !annul;
    end
  end

  assign out = reg_q;

endmodule
