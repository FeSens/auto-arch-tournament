// rtl/wb_stage.sv
//
// Write-back stage. Pure combinational mux that selects between the
// loaded-data path (mem_to_reg=1) and the ALU-result path as seen at the
// MEM/WB register. The regfile is NOT written from here any more: its write
// port is driven from the MEM stage (core.sv, w_data = mem_res), so this
// stage only produces the RVFI retirement write data.
//
// Latency:        combinational.
// RVFI fields:    feeds rd_wdata (= w_data when the instruction writes rd).
module wb_stage (
  // mem_wb_t fields beyond mem_to_reg/read_data/alu_result
  // (pc, mem_*, rs?_*, instr) are RVFI-only and read at top level.
  /* verilator lint_off UNUSEDSIGNAL */
  input  mem_wb_t  in,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0]        w_data
);

  always_comb begin
    w_data = in.ctrl.mem_to_reg ? in.read_data : in.alu_result;
  end

endmodule
