// rtl/wb_stage.sv
//
// Write-back stage. Pure combinational mux that selects between the
// loaded-data path (mem_to_reg=1) and the ALU-result path. Drives the
// regfile write port; the regfile itself stalls on x0 and gates on
// w_en.
//
// Latency:        combinational.
// RVFI fields:    feeds rd_wdata (= w_data when w_en=1, else 0).
module wb_stage
  import core_pkg::*;
(
  // mem_wb_t fields beyond reg_write/rd/mem_to_reg/read_data/alu_result
  // (pc, mem_*, rs?_*, instr) are RVFI-only and read at top level.
  /* verilator lint_off UNUSEDSIGNAL */
  input  mem_wb_t     in,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic        w_en,
  output logic [4:0]  w_addr,
  output logic [31:0] w_data
);

  always_comb begin
    w_en   = in.ctrl.reg_write && in.valid;
    w_addr = in.rd;
    w_data = in.ctrl.mem_to_reg ? in.read_data : in.alu_result;
  end

endmodule
