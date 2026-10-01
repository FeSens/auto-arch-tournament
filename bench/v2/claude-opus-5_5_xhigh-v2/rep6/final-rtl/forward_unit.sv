// rtl/forward_unit.sv
//
// Operand forwarding, resolved one cycle early. Runs in ID on the raw
// IF/ID rs1/rs2 fields and produces the select the instruction will use
// when it sits in EX next cycle. It is latched into ID/EX, so the EX
// operand mux is a registered-select 2:1 with no comparator in front of it.
//
// When ID/EX captures the instruction, next cycle EX/MEM = the current
// ID/EX instruction -> compare against id_ex_rd. Everything older is
// merged into the latched register value by id_stage: the instruction in
// MEM this cycle (its merged result, bypassed into ID) and the one writing
// the regfile this cycle (w_q, write-first bypass). (id_stage holds the
// selects together with the rest of ID/EX when ID/EX holds: on dmem stall
// EX/MEM holds too, and a div that holds ID/EX on ex_busy latched its
// operands on its first EX cycle.)
//
// EX/MEM.reg_write differs from ID/EX.reg_write only for a trapping
// JALR (misaligned target: the redirect to pc+4 kills the follower) or a
// misaligned load (load-use interlock keeps the follower out of EX), so
// the early compare is exact.
//
// x0 never hits a writer, so it selects the register value, which is 0.
//
// Latency:        combinational.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic [4:0] if_id_rs1,
  input  logic [4:0] if_id_rs2,
  input  logic [4:0] id_ex_rd,
  input  logic       id_ex_w_en,
  output opsel_t     sel_rs1,
  output opsel_t     sel_rs2
);

  logic ex_ok;

  always_comb begin
    ex_ok      = id_ex_w_en && id_ex_rd != 5'b0;
    sel_rs1.rf = !(ex_ok && id_ex_rd == if_id_rs1);
    sel_rs2.rf = !(ex_ok && id_ex_rd == if_id_rs2);
  end

endmodule
