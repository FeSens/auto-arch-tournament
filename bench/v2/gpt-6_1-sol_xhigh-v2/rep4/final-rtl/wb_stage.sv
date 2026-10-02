// rtl/wb_stage.sv
//
// Write-back stage. Drives the regfile from MEM/WB's authoritative final
// selected result. The same data wire feeds EX bypass and RVFI rd_wdata.
// The regfile itself drops x0 writes and gates on w_en.
//
// Latency:        combinational.
// RVFI fields:    feeds rd_wdata (= w_data when w_en=1, else 0).
module wb_stage (
  // mem_wb_t fields beyond valid/reg_write/rd/alu_result
  // (pc, mem_*, rs?_*, instr) are RVFI-only and read at top level.
  /* verilator lint_off UNUSEDSIGNAL */
  input  mem_wb_t  in,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic               w_en,
  output logic [4:0]         w_addr,
  output logic [31:0]        w_data
);

  always_comb begin
    w_en   = in.ctrl.reg_write && in.valid;
    w_addr = in.rd;
    w_data = in.alu_result;
  end

endmodule
