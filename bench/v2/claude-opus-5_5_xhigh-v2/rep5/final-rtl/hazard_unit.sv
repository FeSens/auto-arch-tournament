// rtl/hazard_unit.sv
//
// Detects the only data hazard the textbook 5-stage doesn't cover via
// forwarding: load-use. A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
//
// IF/ID is a register (if_stage.sv): the load-use compare reads its rs
// fields (flops). imem readiness never reaches ID: an empty IF/ID (!valid)
// is the ID bubble. The F stage's IF/ID accept logic takes backend_stall.
//
// Outputs:
//   backend_stall       : ID cannot take the IF/ID entry this cycle
//                         (load-use, dmem stall or a running divide).
//   stall_id            : ID/EX register holds.
//   flush_id            : in a fetch-override cycle (the cycle after an
//                         EX redirect), kill the wrong-path instruction
//                         in ID; also injects the load-use bubble.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_mem_read,    // ID/EX.ctrl.mem_read (LOAD in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       ovr,               // fetch-override cycle (registered
                                        // EX redirect): ID is wrong-path
  // dmem bus backpressure (default-1 in zero-wait testbenches;
  // VexRiscv-style random ~22% stall in the benches).
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up).
  input  logic       ex_mem_mem_op,
  // Multi-cycle DIV/REM in EX has not finished: hold ID/EX (no flush).
  // EX/MEM captures bubbles itself (ex_stage).
  input  logic       div_stall,
  output logic       backend_stall,     // IF/ID holds if valid
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_id,          // ID/EX register captures bubble
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic dmem_stall;

  always_comb begin
    // The compare runs against the IF/ID word even when it is invalid:
    // a spurious hit only bubbles an ID/EX slot that is a bubble anyway,
    // and an empty IF/ID accepts regardless of backend_stall.
    load_use_hazard = id_ex_mem_read
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
    // dmem stall only matters if there's actually a memory op in EX/MEM.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    backend_stall = load_use_hazard || dmem_stall || div_stall;
    // ID/EX register:
    //   - dmem_stall  -> hold        (preserve in-flight pipeline state)
    //   - load_use    -> bubble      (1-cycle stall between LOAD + use)
    //   - ovr         -> bubble      (kill wrong-path IF/ID entry)
    //   - div_stall   -> hold        (DIV* waits in ID/EX; it is never
    //                                 a LOAD or a redirect)
    //   - otherwise   -> capture
    // dmem_stall takes precedence over load_use's bubble: re-evaluate
    // load_use next cycle when the bus unblocks. No dmem stall can occur
    // in an ovr cycle (EX/MEM holds the redirecting branch/JALR or a
    // killed bubble), and EX gates div_stall off while ovr.
    stall_id      = dmem_stall || load_use_hazard || div_stall;
    flush_id      = (load_use_hazard || ovr) && !dmem_stall;
    // EX/MEM register: holds on dmem_stall (LOAD waits in MEM until the
    // bus delivers).
    stall_ex_mem  = dmem_stall;
    // MEM/WB register: on dmem_stall the previously-retired instruction's
    // data fields stay alive for forwarding, but valid is cleared so we
    // don't double-retire / double-write the regfile.
    hold_mem_wb   = dmem_stall;
  end

endmodule
