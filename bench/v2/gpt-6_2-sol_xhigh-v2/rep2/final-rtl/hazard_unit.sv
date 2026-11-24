// rtl/hazard_unit.sv
//
// Detects the only data hazard the textbook 5-stage doesn't cover via
// forwarding: load-use. A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle. Also handles dmem backpressure
// and holds ID/EX while the M-extension lane works.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_mem_read,    // ID/EX.ctrl.mem_read (LOAD in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  input  logic       ex_valid,          // EX has a live instruction
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       m_wait,            // EX holds an M instruction without a result
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  output logic       decode_ready,      // ID/EX can accept if a word is valid
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic dmem_stall;

  assign load_use_hazard = ex_valid && id_ex_mem_read
                        && (id_ex_rd != 5'b0)
                        && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2);
  assign dmem_stall = !dmem_ready && ex_mem_mem_op;

  // If ID/EX can advance, load-use or an unavailable word inserts a bubble.
  assign stall_id      = dmem_stall || m_wait;
  assign decode_ready  = !load_use_hazard && !stall_id;
  assign stall_ex_mem  = dmem_stall;
  // MEM/WB clears retirement while preserving its forwarding data.
  assign hold_mem_wb  = dmem_stall;

endmodule
