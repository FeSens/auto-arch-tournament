// rtl/hazard_unit.sv
//
// Handles load-use and M execution backpressure. A LOAD in EX produces its
// data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
//
// Outputs:
//   stall_if / stall_id : hold the fetch head and ID/EX payload respectively.
//   flush_if / flush_id : on EX misprediction, invalidate the younger
//                          fetch and ID/EX entry (payload remains raw).
//   flush_id            : also kills ID's own register on load-use to
//                          inject a single-cycle bubble between LOAD
//                          and the dependent instruction.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_mem_read,    // ID/EX.ctrl.mem_read (LOAD in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       redirect,          // advancing EX misprediction
  // Internal instruction availability includes buffered heads during
  // physical imem stalls. Data readiness is the external bus handshake.
  input  logic       imem_ready,        // buffered head or ready empty bypass
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  input  logic       ex_hold,           // M unit holds EX, MEM may drain
  output logic       stall_if,          // presented head holds; fetch may fill
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_if,          // IF/ID valid -> 0
  output logic       flush_id,          // ID/EX valid -> 0
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic imem_stall;
  logic dmem_stall;

  assign load_use_hazard = imem_ready && id_ex_mem_read
                           && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                           && (id_ex_rd != 5'b0);
  assign imem_stall = !imem_ready;
  // Data backpressure matters only for an actual EX/MEM memory op.
  assign dmem_stall = !dmem_ready && ex_mem_mem_op;

  // Decode consumption holds on any stall reason. Physical fetch has
  // independent capacity admission in IF and may fill through this hold.
  assign stall_if = load_use_hazard || imem_stall || dmem_stall || ex_hold;
  // Unavailable or squashed fetches carry raw payload and invalid status.
  assign flush_if = redirect || imem_stall;
  // ID/EX register:
  //   - dmem_stall / ex_hold -> hold (preserve the EX instruction)
  //   - load_use            -> bubble (one cycle between LOAD + use)
  //   - redirect            -> bubble (kill wrong path)
  //   - otherwise           -> capture
  // Data and M holds take precedence over the load-use bubble; re-evaluate
  // when the older instruction can advance.
  assign stall_id = dmem_stall || load_use_hazard || ex_hold;
  assign flush_id = (load_use_hazard || redirect) && !dmem_stall && !ex_hold;
  // EX/MEM holds its memory request until the bus delivers.
  assign stall_ex_mem = dmem_stall;
  // Only data-memory backpressure blocks MEM. M execution lets older
  // instructions drain. On a data stall, retain WB data but clear valid
  // to prevent duplicate retirement; ID refreshes held operands on WB.
  assign hold_mem_wb = dmem_stall;

endmodule
