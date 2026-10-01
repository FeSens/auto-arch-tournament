// rtl/wb_stage.sv
//
// Write-back stage. The unified result was selected before MEM/WB. Drives the
// regfile write port; the regfile itself stalls on x0 and gates on
// w_en.
//
// Latency:        combinational.
// RVFI fields:    feeds rd_wdata (= w_data when w_en=1, else 0).
module wb_stage (
  // mem_wb_t fields beyond valid/reg_write/rd/write_value
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
    w_data = in.write_value;
  end

endmodule
