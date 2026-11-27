// rtl/wb_stage.sv
//
// Write-back stage. The load-data / ALU-result mux now sits in FRONT of the
// MEM/WB register (mem_stage), so the write-back value is a single
// registered word: MEM/WB.alu_result. That makes the regfile write data and
// the MEM/WB forwarding source a plain flop output.
//
// Latency:        combinational (wires only).
// RVFI fields:    feeds rd_wdata (= w_data when w_en=1, else 0).
module wb_stage (
  // mem_wb_t fields beyond reg_write/rd/alu_result (pc, mem_*, rs?_*,
  // instr) are RVFI-only and read at top level.
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
