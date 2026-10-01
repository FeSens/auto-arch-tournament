// rtl/mem_stage.sv
//
// Memory access stage. Drives the dmem read/write ports combinationally
// from the EX/MEM register (address = the registered AGU result
// mem_addr, never the ALU result), sign/zero-extends the loaded data and
// pre-muxes the write-back value (wb_data) into the MEM/WB register.
//
// Byte-lane discipline:
//   - Write data is replicated across all four byte lanes; the
//     byte-mask (mem_wmask) selects the actual destination bytes.
//   - Load: shift the raw word right by `addr[1:0]*8`, then sign- or
//     zero-extend the low 8/16 bits per the LB/LBU/LH/LHU encoding.
//   - For RVFI ALIGNED_MEM, mem_addr is reported word-aligned and the
//     byte position is captured in mem_rmask / mem_wmask.
//
// Misaligned accesses were detected in EX (mem_mis; ctrl already carries
// is_illegal=1 / reg_write=0); here they only gate the dmem strobes off.
//
// Latency:        1 cycle (MEM/WB register clocked here).
// RVFI fields:    feeds mem_addr, mem_rmask, mem_wmask, mem_rdata,
//                 mem_wdata, plus rd_wdata via wb_data.
module mem_stage (
  input  logic               clock,
  input  logic               reset,
  // hold_wb: dmem stall is in effect. MEM/WB's data fields are RETAINED
  // (the instruction there may be the MEM/WB forwarding source of the
  // held instruction in EX), but `valid` is cleared so:
  //   - rvfi_order doesn't increment for held cycles
  //   - wb_stage doesn't write the regfile twice
  input  logic               hold_wb,
  // ex_mem_t carries branch_taken / branch_target / pred_ctr for the
  // BHT update at top level; mem_stage only consumes a subset.
  /* verilator lint_off UNUSEDSIGNAL */
  input  ex_mem_t  in,
  /* verilator lint_on UNUSEDSIGNAL */
  // dmem interface
  output logic [31:0]        dmem_addr,
  output logic [31:0]        dmem_wdata,
  input  logic [31:0]        dmem_rdata,
  output logic [3:0]         dmem_wen,
  output logic               dmem_ren,
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
  logic [31:0] alu_result;
  logic [31:0] wb_data;
  logic        mem_op;
  logic        do_write;
  logic        do_read;

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

    mem_op   = in.ctrl.mem_read || in.ctrl.mem_write;
    do_write = in.ctrl.mem_write && !in.mem_mis;
    do_read  = in.ctrl.mem_read  && !in.mem_mis;

    // Combinational dmem outputs — gated off on misalign.
    dmem_addr  = in.mem_addr;
    dmem_wdata = wdata_rep;
    dmem_wen   = do_write ? byte_mask : 4'b0000;
    dmem_ren   = do_read;

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

    // Merge the unmuxed EX/MEM result legs by the producer's class.
    alu_result = ({32{in.c.add}} & in.sum) | ({32{in.c.sub}} & in.dif)
               | ({32{in.c.sh}}  & in.sh)  | ({32{in.c.lg}}  & in.lg);
    wb_data = in.ctrl.mem_to_reg ? load_data : alu_result;

    // RVFI ALIGNED_MEM expects word-aligned mem_addr; mem_addr=0 if no access.
    aligned_addr = (mem_op && !in.mem_mis)
                 ? {in.mem_addr[31:2], 2'b00}
                 : 32'b0;
  end

  // ── MEM/WB register ───────────────────────────────────────────────────
  mem_wb_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (hold_wb) begin
      // Clear valid (no double-retire / no double-regfile-write), but
      // KEEP every other field: the held instruction in EX may take its
      // operand from wb_data for as many cycles as the dmem stall lasts.
      reg_q.valid <= 1'b0;
    end else begin
      reg_q.pc         <= in.pc;
      reg_q.wb_data    <= wb_data;
      reg_q.rd         <= in.rd;
      reg_q.rs1_addr   <= in.rs1_addr;
      reg_q.rs2_addr   <= in.rs2_addr;
      reg_q.rs1_val    <= in.rs1_val;
      reg_q.rs2_val    <= in.rs2_val;
      reg_q.pc_next    <= in.pc_next;
      reg_q.mem_addr   <= aligned_addr;
      reg_q.mem_rdata  <= dmem_rdata;
      reg_q.mem_wdata  <= wdata_rep;
      reg_q.mem_wmask  <= do_write ? byte_mask : 4'b0000;
      reg_q.mem_rmask  <= do_read  ? byte_mask : 4'b0000;
      reg_q.ctrl       <= in.ctrl;
      reg_q.instr      <= in.instr;
      reg_q.valid      <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
