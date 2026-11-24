// rtl/wb_stage.sv
//
// Drive the register file with the result selected in MEM. A dmem wait
// retains this data for forwarding and clears valid to retire only once.
//
// Latency:        combinational.
// RVFI fields:    feeds rd_wdata (= w_data when w_en=1, else 0).
module wb_stage (
  // EX reads the individual result candidates for JALR verification.
  // The retirement port reads the RVFI fields at the top level.
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
    w_data = in.wb_data;
  end

endmodule
