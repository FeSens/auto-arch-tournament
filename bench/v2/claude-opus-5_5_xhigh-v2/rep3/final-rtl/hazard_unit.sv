// rtl/hazard_unit.sv
//
// Detects the only data hazard the textbook 5-stage doesn't cover via
// forwarding: load-use. A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
//
// The load-use compare reads the RAW fetched instruction (no redirect
// NOP substitution), so nothing here depends on EX's redirect except
// flush_id. A spurious load-use on a wrong-path / imem-stall slot is
// harmless: redirect overrides the PC stall, flush overrides stall_id.
//
// Outputs:
//   stall_if     : freeze the PC reg.
//   stall_id     : ID/EX data fields hold.
//   flush_id     : ID/EX kill bits (valid + side-effect ctrl) clear —
//                  on redirect (wrong path), load-use (bubble) or imem
//                  stall (no instruction delivered). Overrides stall_id
//                  for the kill bits; gated off on dmem/div stall so the
//                  held occupant survives.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_mem_read,    // ID/EX.ctrl.mem_read (LOAD in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  input  logic [4:0] if_id_rs1,         // raw instr[19:15]    (next rs1)
  input  logic [4:0] if_id_rs2,         // raw instr[24:20]    (next rs2)
  input  logic       redirect,          // EX has resolved a branch/jump
  // Bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). When low, the corresponding
  // memory request is NOT serviced this cycle.
  input  logic       imem_ready,
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  // EX holds a DIV* whose iterative result is not ready yet. Holds PC and
  // ID/EX; ex_stage itself feeds bubbles into EX/MEM.
  input  logic       div_stall,
  output logic       stall_if,          // PC reg holds
  output logic       stall_id,          // ID/EX data fields hold
  output logic       flush_id,          // ID/EX kill bits clear
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic imem_stall;
  logic dmem_stall;

  always_comb begin
    load_use_hazard = id_ex_mem_read
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
    imem_stall = !imem_ready;
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // PC reg holds on any stall reason (redirect overrides in if_stage).
    stall_if      = load_use_hazard || imem_stall || dmem_stall || div_stall;
    // ID/EX register:
    //   - dmem_stall  -> hold        (preserve in-flight pipeline state)
    //   - div_stall   -> hold        (DIV waits in EX)
    //   - load_use    -> bubble      (1-cycle stall between LOAD + use)
    //   - redirect    -> bubble      (kill wrong-path)
    //   - imem_stall  -> bubble      (no instruction delivered)
    //   - otherwise   -> capture
    stall_id      = dmem_stall || load_use_hazard || div_stall;
    flush_id      = (redirect || load_use_hazard || imem_stall)
                    && !dmem_stall && !div_stall;
    // EX/MEM register: holds on dmem_stall (LOAD waits in MEM until the
    // bus delivers).
    stall_ex_mem  = dmem_stall;
    // MEM/WB register: on dmem_stall the previously-retired instruction's
    // data fields stay alive for forwarding, but valid is cleared so we
    // don't double-retire / double-write the regfile.
    hold_mem_wb   = dmem_stall;
  end

endmodule
