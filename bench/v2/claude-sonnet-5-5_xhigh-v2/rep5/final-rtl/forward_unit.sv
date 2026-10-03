// rtl/forward_unit.sv
//
// Operand forwarding selects. The 5-bit rs-vs-rd compare is done one cycle
// early, in ID (see id_stage.sv), and registered in the ID/EX payload:
//   m1_rsX : the instruction entering EX writes rsX's register and sits in
//            EX now, i.e. it is in EX/MEM while this instruction is in EX
// What is left for EX is an AND with the *registered* reg_write bit of
// EX/MEM (so trap-suppressed writes and bubbles behave exactly as with a
// combinational compare).
//
// The older leg (the instruction that is in MEM/WB while this one is in EX)
// is not forwarded in EX at all: ID captures its write-back value straight
// into ID/EX.rs?_val (late MEM-result bypass), so EX only has a 2:1 mux.
//
// Select encoding:
//   1'b0 : ID/EX register's rs?_val (already holds the MEM/WB value)
//   1'b1 : the in-flight ALU result from the EX/MEM register
//
// Latency:        combinational (one AND on flops only).
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic m1_rs1,
  input  logic m1_rs2,
  input  logic m1_alu_a,     // m1_rs1 && !is_auipc  (ALU operand A)
  input  logic m1_alu_b,     // m1_rs2 && !alu_src   (ALU operand B)
  input  logic ex_mem_w_en,
  output logic fwd_rs1,
  output logic fwd_rs2,
  output logic fwd_alu_a,
  output logic fwd_alu_b
);

  assign fwd_rs1   = m1_rs1   && ex_mem_w_en;
  assign fwd_rs2   = m1_rs2   && ex_mem_w_en;
  assign fwd_alu_a = m1_alu_a && ex_mem_w_en;
  assign fwd_alu_b = m1_alu_b && ex_mem_w_en;

endmodule
