// A load or RV32M producer writes its result in MEM/WB. Wait one cycle
// before decoding a following instruction that needs either raw source field.
// Aligned conditional branches can compare a load in the following EX cycle.
module hazard_unit (
  input  logic       id_ex_valid,
  input  logic       id_ex_late,
  input  logic       id_ex_load,
  input  logic [4:0] id_ex_rd,
  input  fetch_hazard_t fetch,
  input  logic       div_wait,
  input  logic       dmem_ready,
  input  logic       ex_mem_mem_op,
  output load_match_t load_match,
  output logic       late_dependency,
  output logic       stall_id,
  output logic       flush_id,
  output logic       stall_ex_mem
);

  logic late_writer, defer_branch;
  logic rs1_match, rs2_match;

  // An empty fetch input never advances an instruction, even if its
  // source bits happen to match. On correction the EX valid is masked.
  assign late_writer = id_ex_valid && id_ex_late && id_ex_rd != 5'b0;
  assign defer_branch = id_ex_load && fetch.aligned_branch;
  assign rs1_match = id_ex_rd == fetch.rs1;
  assign rs2_match = id_ex_rd == fetch.rs2;
  assign load_match.rs1 = late_writer && defer_branch && rs1_match;
  assign load_match.rs2 = late_writer && defer_branch && rs2_match;
  // RVFI reports even source fields that the decoded instruction ignores.
  assign late_dependency = late_writer && !defer_branch && (rs1_match || rs2_match);

  assign stall_ex_mem = ex_mem_mem_op && !dmem_ready;
  // ID/EX holds for older memory or for a divide still executing. With
  // neither hold active, flush_id only clears the incoming valid bit.
  assign stall_id     = stall_ex_mem || div_wait;
  assign flush_id     = late_dependency;

endmodule
