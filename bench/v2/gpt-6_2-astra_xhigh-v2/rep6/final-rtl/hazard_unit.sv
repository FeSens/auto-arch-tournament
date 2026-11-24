// rtl/hazard_unit.sv
//
// Multiply and divide consumers wait for WB. Load consumers enter EX immediately
// and retry locally after a failed address or format check.
//
// IF and ID share a cycle. On a data hazard IF retries the same PC
// and ID inserts a bubble. An EX correction squashes the single younger
// slot. Holds for memory or divide take priority at ID/EX.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_wb_only,     // valid EX producer first bypassed in WB
  input  logic [4:0] id_ex_rd,          // ID/EX destination
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       redirect,          // EX has resolved a branch/jump
  input  logic       div_wait,          // held divide still needs EX
  input  logic       replay,
  input  logic       fetch_available,   // live bus word or verified successor
  input  logic       dmem_ready,
  input  logic       bus_request,       // load miss or store at the true address
  output logic       stall_if,          // PC reg holds
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_id,          // bubble entering EX
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic use_hazard;
  logic dmem_stall;

  assign use_hazard   = id_ex_wb_only && id_ex_rd != 5'b0
                     && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2);
  assign dmem_stall   = !dmem_ready && bus_request;
  assign stall_id     = dmem_stall || div_wait || replay;
  assign stall_if     = stall_id || use_hazard || !fetch_available;
  assign flush_id     = use_hazard || redirect;
  assign stall_ex_mem = dmem_stall;
  assign hold_mem_wb  = dmem_stall;

endmodule
