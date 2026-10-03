// rtl/hazard_unit.sv
//
// Detects the only data hazard the textbook 5-stage doesn't cover via
// forwarding: load-use. A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
//
// Outputs:
//   stall_if / stall_id : freeze the fetch PC and the F/D register (stall_if),
//                          and the ID/EX register (stall_id). imem backpressure
//                          is NOT a stall: a fetch without an instruction
//                          becomes a bubble in the F/D register itself.
//   mdu_stall           : also holds PC and ID/EX while a multi-cycle M-op
//                          occupies EX (flush_id is not asserted for it; an
//                          M-op can neither redirect nor be a load).
//   flush_id            : on EX redirect (kill) drop the wrong-path F/D
//                          instruction at the ID/EX register; also on load-use
//                          to inject a single-cycle bubble between LOAD
//                          and the dependent instruction.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_mem_read,    // ID/EX.ctrl.mem_read (LOAD in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  input  logic [4:0] if_id_rs1,         // F/D instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // F/D instr[24:20]  (next rs2)
  input  logic       kill,              // registered EX mispredict recovery
  // dmem bus backpressure (default-1 in zero-wait testbenches; random ~22%
  // stall in the evaluation harness). When low, the memory request is NOT
  // serviced this cycle. (imem backpressure is handled inside if_stage.)
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  // An M-op is in EX and the MDU has not produced its result yet. Holds
  // the PC and ID/EX like a dmem stall (no bubble: the M-op stays in EX).
  input  logic       mdu_stall,
  output logic       stall_if,          // fetch PC + F/D register hold
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_id,          // ID/EX register captures '0
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic dmem_stall;

  always_comb begin
    load_use_hazard = id_ex_mem_read
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // Fetch PC and F/D hold on any stall reason (all early flop / input
    // terms; no imem_ready, no cache hit).
    stall_if      = load_use_hazard || dmem_stall || mdu_stall;
    // ID/EX register:
    //   - dmem_stall  -> hold        (preserve in-flight pipeline state)
    //   - load_use    -> bubble      (1-cycle stall between LOAD + use)
    //   - kill        -> bubble      (drop the wrong-path F/D instruction)
    //   - otherwise   -> capture
    // dmem_stall takes precedence over load_use's bubble: re-evaluate
    // load_use next cycle when the bus unblocks. flush_id is 1 only when
    // we want bubble (not hold). While kill is held through a dmem stall the
    // wrong-path instruction in EX is held too (ex_stage keeps kill high and
    // turns it into a bubble once the stall ends).
    stall_id      = dmem_stall || load_use_hazard || mdu_stall;
    flush_id      = (load_use_hazard || kill) && !dmem_stall;
    // EX/MEM register: holds on dmem_stall (LOAD waits in MEM until the
    // bus delivers).
    stall_ex_mem  = dmem_stall;
    // MEM/WB register: on dmem_stall the previously-retired instruction's
    // data fields stay alive for forwarding (e.g. a held BNE needs the
    // LOAD's load_data via fwd_mem_wb), but valid is cleared so we don't
    // double-retire / double-write the regfile.
    hold_mem_wb   = dmem_stall;
  end

endmodule
