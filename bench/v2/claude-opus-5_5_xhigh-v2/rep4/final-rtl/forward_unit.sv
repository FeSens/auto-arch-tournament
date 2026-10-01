// rtl/forward_unit.sv
//
// ID-side operand-source select for one source register. Evaluated one
// cycle ahead of use: for the instruction in ID, it predicts where the
// freshest value of `rs` will live while that instruction is in EX.
//   sel_x  : the instruction now in ID/EX (it will be in EX/MEM)
//   sel_w  : the instruction now in EX/MEM (it will be in MEM/WB)
//   sel_rf : neither — the regfile read (write-first bypassed) is final
//
// The prediction holds because ID/EX only captures when ID/EX, EX/MEM
// and MEM/WB all advance together (no dmem stall, no M-op stall), and a
// held consumer keeps its sources in place (dmem stall freezes EX/MEM,
// MEM/WB keeps its data). A load at distance 1 is removed by the load-use
// bubble; a trapping (misaligned) JAL/JALR at distance 1 redirects to
// pc+4, killing the consumer so it re-evaluates here. Misaligned loads
// have reg_write cleared in EX, before they reach the EX/MEM compare.
//
// Priority is ID/EX > EX/MEM > regfile (younger writer wins, x0 never
// forwarded). The three outputs are one-hot.
//
// Latency:        combinational.
// RVFI fields:    n/a — steers rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic [4:0] rs,
  input  logic [4:0] id_ex_rd,
  input  logic       id_ex_w_en,
  input  logic [4:0] ex_mem_rd,
  input  logic       ex_mem_w_en,
  output logic       sel_x,
  output logic       sel_w,
  output logic       sel_rf
);

  always_comb begin
    sel_x  = id_ex_w_en  && id_ex_rd  != 5'b0 && id_ex_rd  == rs;
    sel_w  = !sel_x &&
             ex_mem_w_en && ex_mem_rd != 5'b0 && ex_mem_rd == rs;
    sel_rf = !sel_x && !sel_w;
  end

endmodule
