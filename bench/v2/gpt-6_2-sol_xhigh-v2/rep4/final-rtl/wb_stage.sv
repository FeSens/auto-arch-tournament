// rtl/wb_stage.sv
//
// Write-back stage. Drives the register file from the selected commit slot.
//
// Latency:        combinational.
// RVFI fields:    feeds rd_wdata (= w_data when w_en=1, else 0).
module wb_stage (
  // The remaining payload fields feed RVFI at top level.
  /* verilator lint_off UNUSEDSIGNAL */
  input  mem_wb_t  in,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic               w_en,
  output logic [4:0]         w_addr,
  output logic [31:0]        w_data
);

  always_comb begin
    w_en   = in.valid && in.reg_write && (in.rd != 5'b0);
    w_addr = in.rd;
    w_data = in.write_value;
  end

endmodule
