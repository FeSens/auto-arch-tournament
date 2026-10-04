// rtl/forward_unit.sv
//
// Resolve complete decode operands before their ID/EX capture. The EX
// completion candidate wins over MEM's final writeback value, then the
// write-first register-file output supplies the architectural value.
// WB bypass and x0 handling belong solely to the register file.
//
// Latency:        combinational.
// RVFI fields:    feeds the captured architectural rs1_rdata / rs2_rdata.
module forward_unit (
  input  logic [4:0]  rs1_addr,
  input  logic [4:0]  rs2_addr,
  input  logic [31:0] rf_rs1_data,
  input  logic [31:0] rf_rs2_data,
  input  logic [4:0]  ex_rd,
  input  logic        ex_wen,
  input  logic [31:0] ex_data,
  input  logic [4:0]  mem_rd,
  input  logic        mem_wen,
  input  logic [31:0] mem_data,
  output logic [31:0] rs1_data,
  output logic [31:0] rs2_data
);

  logic rs1_e, rs1_m, rs1_r;
  logic rs2_e, rs2_m, rs2_r;

  // Tag comparisons run alongside producer data computation. Nonzero
  // producer tags exclude x0 without another mux on the resolved data.
  assign rs1_e = ex_wen && ex_rd != 5'b0 && ex_rd == rs1_addr;
  assign rs1_m = !rs1_e && mem_wen && mem_rd != 5'b0 && mem_rd == rs1_addr;
  assign rs1_r = !rs1_e && !rs1_m;
  assign rs2_e = ex_wen && ex_rd != 5'b0 && ex_rd == rs2_addr;
  assign rs2_m = !rs2_e && mem_wen && mem_rd != 5'b0 && mem_rd == rs2_addr;
  assign rs2_r = !rs2_e && !rs2_m;

  assign rs1_data = (ex_data & {32{rs1_e}})
                  | (mem_data & {32{rs1_m}})
                  | (rf_rs1_data & {32{rs1_r}});
  assign rs2_data = (ex_data & {32{rs2_e}})
                  | (mem_data & {32{rs2_m}})
                  | (rf_rs2_data & {32{rs2_r}});

endmodule
