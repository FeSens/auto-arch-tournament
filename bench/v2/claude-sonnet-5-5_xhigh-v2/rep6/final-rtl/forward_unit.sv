// rtl/forward_unit.sv
//
// Operand forwarding.
//
// ID-stage select generator (timed): while instruction I sits in ID, its
// rs1/rs2 are compared with the rd of the instruction in EX (id_ex) and in
// MEM (ex_mem).
//   sel_*_ex : producer in EX. When ID/EX captures I the producer moves to
//              EX/MEM, so EX forwards its result from there next cycle.
//   sel_*_wb : producer in MEM. Its result (mem_stage.wb_next) already
//              exists this cycle, so id_stage captures it straight into the
//              ID/EX operand; EX never needs the MEM/WB leg. Gated with
//              wb_next_ok (reg_write after the misalign trap) so a
//              trap-cancelled LOAD in MEM is not forwarded; the older
//              producer (in WB) is then covered by the regfile write-first
//              bypass.
// The two matches are independent (sel_wb is not masked by sel_ex): a
// producer whose reg_write is cleared later by a trap (misaligned JAL/JALR
// in EX) is dropped in EX by gating with the producer's registered
// reg_write, and the ID/EX operand (MEM producer > WB producer > regfile)
// must then still hold the older value. Priority (EX/MEM > ID/EX operand)
// is applied in ex_stage.
//
// EX-stage compare (RVFI only): the original combinational compare of the
// ID/EX rs1 against EX/MEM and MEM/WB. Its output only feeds the RVFI
// rs1_rdata report, so it is pruned from the timed netlist.
//   00 : ID/EX register's rs1_val
//   01 : EX/MEM aluResult
//   10 : MEM/WB write data
//
// Latency:        combinational.
// RVFI fields:    n/a — fwd_rs1 feeds rs1_rdata via the EX-stage mux.
module forward_unit (
  // ID-stage select generation
  input  logic [4:0] if_id_rs1,
  input  logic [4:0] if_id_rs2,
  input  logic [4:0] id_ex_rd,
  input  logic       id_ex_w_en,
  output logic       sel1_ex,
  output logic       sel1_wb,
  output logic       sel2_ex,
  output logic       sel2_wb,
  // instruction currently in the MEM stage (EX/MEM register)
  input  logic [4:0] ex_mem_rd,
  input  logic       wb_next_ok,    // MEM-stage reg_write after the misalign trap
  // RVFI-only EX-stage compare
  input  logic       ex_mem_w_en,
  input  logic [4:0] id_ex_rs1,
  input  logic [4:0] mem_wb_rd,
  input  logic       mem_wb_w_en,
  output logic [1:0] fwd_rs1
);

  logic id_ex_wr;
  logic ex_mem_wr;

  always_comb begin
    id_ex_wr  = id_ex_w_en  && (id_ex_rd  != 5'b0);
    ex_mem_wr = wb_next_ok  && (ex_mem_rd != 5'b0);

    sel1_ex = id_ex_wr  && (id_ex_rd  == if_id_rs1);
    sel1_wb = ex_mem_wr && (ex_mem_rd == if_id_rs1);
    sel2_ex = id_ex_wr  && (id_ex_rd  == if_id_rs2);
    sel2_wb = ex_mem_wr && (ex_mem_rd == if_id_rs2);
  end

  // Yosys's Verilog frontend rejects SV-style `function … return …`.
  always_comb begin
    if      (ex_mem_w_en && ex_mem_rd != 5'b0 && ex_mem_rd == id_ex_rs1) fwd_rs1 = 2'd1;
    else if (mem_wb_w_en && mem_wb_rd != 5'b0 && mem_wb_rd == id_ex_rs1) fwd_rs1 = 2'd2;
    else                                                                  fwd_rs1 = 2'd0;
  end

endmodule
