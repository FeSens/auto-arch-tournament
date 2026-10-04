// rtl/hazard_unit.sv
//
// Load-use interlock, memory backpressure and blocking divider control.
// Divider waits hold fetch/decode while EX/MEM and MEM/WB drain; only a
// data-memory stall holds EX/MEM and preserves older WB forwarding data.
//
// Outputs:
//   stall_if / stall_id : hold the fetch consumer and ID/EX respectively;
//                          an empty skid buffer may still accept a response.
//   flush_if / flush_id : on EX redirect, kill queued/bypassed fetch and
//                          current ID/EX eligibility.
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
  input  logic       if_id_valid,       // raw consumer availability, before flush
  input  logic       redirect,          // EX has resolved a branch/jump
  // Instruction readiness is consumer availability (buffer full OR raw
  // bus ready). Raw producer readiness belongs solely to if_stage.
  input  logic       imem_ready,
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  input  logic       divider_wait,
  output logic       stall_if,          // fetch consumer holds
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_if,          // IF/ID comb valid -> 0
  output logic       flush_id,          // kill ID/EX validity and controls
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic imem_stall;
  logic dmem_stall;

  assign load_use_hazard = if_id_valid && id_ex_mem_read
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
  assign imem_stall = !imem_ready;
  // dmem stall only matters if there's actually a memory op in EX/MEM.
  assign dmem_stall = !dmem_ready && ex_mem_mem_op;

  // Consumer holds on any stall reason; producer capacity is independent.
  assign stall_if = load_use_hazard || imem_stall || dmem_stall || divider_wait;
  // Suppress decode validity on redirect or absent consumer instruction.
  assign flush_if = redirect || imem_stall;
  // Memory/divider waits hold ID/EX; load-use and redirects inject a
  // bubble only when the current EX instruction can advance.
  assign stall_id = dmem_stall || load_use_hazard || divider_wait;
  assign flush_id = (load_use_hazard || redirect) && !dmem_stall && !divider_wait;
  // A divider wait injects its own EX/MEM bubble; it never holds MEM.
  assign stall_ex_mem = dmem_stall;
  // Preserve WB data for a held instruction, but clear valid to prevent
  // repeated retirement or register writes during a data bus stall.
  assign hold_mem_wb = dmem_stall;

endmodule
