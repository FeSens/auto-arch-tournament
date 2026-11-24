// rtl/mem_stage.sv
//
// Memory access stage. Drives the dmem read/write ports combinationally
// from the EX/MEM register, and sign/zero-extends the loaded data into
// the MEM/WB register.
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
//                 mem_wdata, plus rd_wdata via the loaded-data path.
module mem_stage (
  input  logic               clock,
  input  logic               reset,
  // A data stall holds the MEM/WB bypass value and clears retirement valid.
  input  logic               hold_wb,
  // mem_stage consumes only a subset of ex_mem_t.
  /* verilator lint_off UNUSEDSIGNAL */
  input  ex_mem_t  in,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic               branch_taken,
  // dmem interface
  output logic [31:0]        dmem_addr,
  output logic [31:0]        dmem_wdata,
  input  logic [31:0]        dmem_rdata,
  output logic [3:0]         dmem_wen,
  output logic               dmem_ren,
  output load_response_t     load_response,
  output logic               write_eligible,  // MEM producer for decode
  output mem_wb_t  divide_commit,
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

  // Misaligned mem-access trap. RV32I requires word-aligned LW/SW and
  // halfword-aligned LH/LHU/SH; byte ops are always aligned.
  // riscv-formal's RISCV_FORMAL_ALIGNED_MEM contract demands rvfi_trap=1
  // when the effective byte address is not aligned to the access width.
  // On trap, the dmem ports are gated off and ctrl propagates is_illegal.
  logic mem_misalign;
  logic mem_op;

  assign write_eligible = in.valid && in.ctrl.reg_write && !mem_misalign;

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

    mem_op       = in.ctrl.mem_read || in.ctrl.mem_write;
    mem_misalign = mem_op && (
                     (in.ctrl.mem_width == 2'd2 && in.effective_addr[1:0] != 2'b00) ||
                     (in.ctrl.mem_width == 2'd1 && in.effective_addr[0]   != 1'b0)
                     // 2'd0 (byte) is never misaligned.
                   );

    // Combinational dmem outputs — gated off on misalign.
    dmem_addr  = in.effective_addr;
    dmem_wdata = wdata_rep;
    dmem_wen   = (in.ctrl.mem_write && !mem_misalign) ? byte_mask : 4'b0000;
    dmem_ren   = in.ctrl.mem_read  && !mem_misalign;

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

  assign load_response.value       = load_data;
  assign load_response.lane        = in.effective_addr[1:0];
  assign load_response.width       = in.ctrl.mem_width;
  assign load_response.sign_extend = in.ctrl.mem_sext;
  // EX uses this response only on the edge on which the request advances.
  assign load_response.valid       = dmem_ren;

  // ── MEM/WB register ───────────────────────────────────────────────────
  mem_wb_t next_wb, reg_q;
  logic retire_divide, branch_misalign;

  // A divide holds EX while older instructions drain. Once it reaches
  // MEM, it owns the single commit slot and still advances its bypass
  // data. Only a memory request in this stage can assert hold_wb.
  assign retire_divide = in.valid && in.is_divide;
  assign branch_misalign = in.ctrl.is_branch && branch_taken && in.branch_target[1];

  always_comb begin
    next_wb.pc          = in.pc;
    next_wb.write_value = in.ctrl.mem_to_reg ? load_data : in.alu_result;
    next_wb.rd          = in.rd;
    next_wb.rs1_addr    = in.rs1_addr;
    next_wb.rs2_addr    = in.rs2_addr;
    next_wb.rs1_val     = in.rs1_val;
    next_wb.rs2_val     = in.rs2_val;
    next_wb.pc_next     = in.ctrl.is_branch && branch_taken && !in.branch_target[1]
                        ? in.branch_target : in.pc_next;
    next_wb.mem_addr    = aligned_addr;
    next_wb.mem_rdata   = dmem_rdata;
    next_wb.mem_wdata   = wdata_rep;
    next_wb.mem_wmask   = dmem_wen;
    next_wb.mem_rmask   = dmem_ren ? byte_mask : 4'b0000;
    next_wb.reg_write   = write_eligible;
    next_wb.trap        = in.ctrl.is_illegal || mem_misalign || branch_misalign;
    next_wb.instr       = in.instr;
    next_wb.valid       = in.valid && !retire_divide;

    divide_commit             = next_wb;
    divide_commit.write_value = in.alu_result;
    divide_commit.valid       = retire_divide;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (hold_wb) begin
      // The held EX instruction can still select this MEM/WB value.
      reg_q.valid <= 1'b0;
    end else begin
      reg_q <= next_wb;
    end
  end

  assign out = reg_q;

endmodule
