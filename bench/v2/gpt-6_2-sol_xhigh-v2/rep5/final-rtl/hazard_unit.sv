// rtl/hazard_unit.sv
//
// Interlocks the pipeline for late results, DIV/REM, and bus stalls.
// Eligible consumers take the late result through MEM/WB in their MEM cycle.
// Other dependent instructions wait one cycle to forward it in EX.
// A divide holds issue and ID/EX while the older stages drain.
//
// A late-result dependency holds the FIFO head and inserts a bubble.
// Only EX backpressure holds an existing ID/EX entry in place.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_late_result,
  input  logic [4:0] id_ex_rd,
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       late_eligible,
  input  logic       divide_wait,       // DIV/REM in EX has no result yet
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  output logic       pending_rs1,
  output logic       pending_rs2,
  output logic       stall_issue,       // FIFO head cannot issue
  output logic       hold_id_ex,        // ID/EX register holds
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  // RVFI records both encoded source values, including unused operands.
  logic late_write;
  assign late_write = id_ex_late_result && id_ex_rd != 5'b0;
  assign pending_rs1 = late_write && id_ex_rd == if_id_rs1;
  assign pending_rs2 = late_write && id_ex_rd == if_id_rs2;
  assign stall_ex_mem = !dmem_ready && ex_mem_mem_op;
  assign hold_mem_wb  = stall_ex_mem;

  assign hold_id_ex = stall_ex_mem || divide_wait;
  assign stall_issue = hold_id_ex || (!late_eligible && (pending_rs1 || pending_rs2));

endmodule
