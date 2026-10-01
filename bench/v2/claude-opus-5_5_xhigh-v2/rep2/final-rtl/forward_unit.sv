// rtl/forward_unit.sv
//
// EX-stage 1-ahead bypass selects. The only producer EX still forwards
// from is the instruction immediately ahead (now in EX/MEM); the 2-ahead
// forward happens in ID (id_stage, from mem_stage's mem_result) and the
// 3-ahead one is the regfile write-first bypass. The rd == rs compares
// are done one cycle early in ID (registered hit bits in ID/EX), so here
// each hit is only qualified with the live EX/MEM reg_write bit.
// Qualifying late keeps traps exact: a misaligned jump (EX) clears
// reg_write after the hit was registered, and a DIV* bubble carries
// reg_write = 0.
//
// Each select plus its 2:1 data mux in ex_stage fits one LUT4 per bit.
//
// Latency:        combinational (one AND off flops).
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic rs1_hit_ex,
  input  logic rs2_hit_ex,
  input  logic op_a_hit,
  input  logic op_b_hit,
  input  logic ex_mem_w_en,
  output logic fwd_rs1,
  output logic fwd_rs2,
  output logic fwd_a,
  output logic fwd_b
);

  always_comb begin
    fwd_rs1 = rs1_hit_ex && ex_mem_w_en;
    fwd_rs2 = rs2_hit_ex && ex_mem_w_en;
    fwd_a   = op_a_hit   && ex_mem_w_en;
    fwd_b   = op_b_hit   && ex_mem_w_en;
  end

endmodule
