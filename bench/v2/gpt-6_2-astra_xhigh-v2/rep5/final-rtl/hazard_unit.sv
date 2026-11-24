// Hold the pipeline behind a waiting memory operation or divide. A
// load-use interlock holds the PC and inserts a single bubble into EX.
module hazard_unit (
  input  logic       id_ex_mem_read,
  input  logic [4:0] id_ex_rd,
  input  logic [4:0] if_id_rs1,
  input  logic [4:0] if_id_rs2,
  input  logic       redirect,
  input  logic       fetch_valid,
  input  logic       dmem_ready,
  input  logic       ex_mem_mem_op,
  input  logic       div_wait,
  output logic       stall_if,
  output logic       stall_id,
  output logic       flush_id,
  output logic       stall_ex_mem,
  output logic       hold_mem_wb
);
  logic load_use_hazard;

  assign load_use_hazard = fetch_valid && id_ex_mem_read && id_ex_rd != 0 &&
                           (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2);
  assign stall_ex_mem = ex_mem_mem_op && !dmem_ready;
  assign hold_mem_wb  = stall_ex_mem;
  assign stall_id     = stall_ex_mem || div_wait;
  assign stall_if     = stall_id || load_use_hazard || !fetch_valid;
  assign flush_id     = redirect || load_use_hazard;
endmodule
