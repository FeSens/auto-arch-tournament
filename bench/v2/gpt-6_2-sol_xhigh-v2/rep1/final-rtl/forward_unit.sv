// Qualify the matches captured by ID with the producers' writer controls.
module forward_unit (
  input  logic [1:0] ex_match,
  input  logic [1:0] mem_match,
  input  logic       ex_mem_w_en,
  input  result_sel_t ex_mem_sel,
  input  logic       mem_wb_w_en,
  output fwd_sel_t   fwd_rs1,
  output fwd_sel_t   fwd_rs2
);

  logic [1:0] younger, older;

  assign younger = ex_match & {2{ex_mem_w_en}};
  assign older = mem_match & {2{mem_wb_w_en}};

  // A trapped producer has its writer control cleared before this point,
  // so it cannot mask the older value.
  assign fwd_rs1.result  = younger[0] ? ex_mem_sel : '0;
  assign fwd_rs1.wb      = !younger[0] && older[0];
  assign fwd_rs1.regfile = !younger[0] && !older[0];

  assign fwd_rs2.result  = younger[1] ? ex_mem_sel : '0;
  assign fwd_rs2.wb      = !younger[1] && older[1];
  assign fwd_rs2.regfile = !younger[1] && !older[1];

endmodule
