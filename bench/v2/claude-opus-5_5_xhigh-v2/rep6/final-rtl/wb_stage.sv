// rtl/wb_stage.sv
//
// Regfile write port. Not a datapath stage any more: the load / mul / alu
// merge happens in MEM, whose result is bypassed straight into ID; the
// registered copy w_q = MEM/WB.{w_en, rd, result} writes the regfile one
// cycle after MEM (and is id_stage's second bypass source). w_en already
// excludes x0 and stalled MEM cycles.
//
// Latency:        combinational.
// RVFI fields:    none (rd_wdata is read from MEM/WB at top level).
module wb_stage (
  // mem_wb_t fields beyond w_en/rd/result (pc, mem_*, rs?_*, instr) are
  // RVFI-only and read at top level.
  /* verilator lint_off UNUSEDSIGNAL */
  input  mem_wb_t  in,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic               w_en,
  output logic [4:0]         w_addr,
  output logic [31:0]        w_data
);

  always_comb begin
    w_en   = in.w_en;
    w_addr = in.rd;
    w_data = in.result;
  end

endmodule
