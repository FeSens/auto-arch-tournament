// rtl/wb_stage.sv
//
// Write-back stage. Pure combinational mux that selects the architectural
// result from the registered MEM/WB rails (or load data). Drives the regfile
// write port; the regfile itself stalls on x0 and gates on w_en.
//
// Latency:        combinational.
// RVFI fields:    feeds rd_wdata (= w_data when w_en=1, else 0).
module wb_stage (
  // mem_wb_t fields beyond reg_write/rd/read_data/result rails
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
    case (in.wb_sel)
      WB_SEL_LOAD:   w_data = in.read_data;
      WB_SEL_MUL:    w_data = in.mul_result;
      WB_SEL_DIV:    w_data = in.div_result;
      WB_SEL_JUMP:   w_data = in.jump_result;
      default:       w_data = in.simple_result;
    endcase
  end

endmodule
