// rtl/wb_stage.sv
//
// Write-back stage. The load-data / ALU-result select (mem_to_reg) is done
// in MEM, so this just passes the MEM/WB wb_data flop through. Drives the
// regfile write port; the regfile itself stalls on x0 and gates on
// w_en.
//
// Latency:        combinational.
// RVFI fields:    feeds rd_wdata (= w_data when w_en=1, else 0).
module wb_stage (
  // mem_wb_t fields beyond reg_write/rd/wb_data
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
    w_data = in.wb_data;
  end

endmodule
