// rtl/wb_stage.sv
//
// Write-back stage. Drives the regfile write port from the complete
// result selected and registered by MEM. The regfile drops x0 writes
// and gates on w_en; held EX bypass consumers still see the retained data.
//
// Latency:        combinational.
// RVFI fields:    feeds rd_wdata (= w_data when w_en=1, else 0).
module wb_stage (
  // mem_wb_t fields beyond reg_write/valid/rd/wb_result
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
    // Never gate the retained value with validity or write eligibility.
    w_data = in.wb_result;
  end

endmodule
