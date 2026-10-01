// rtl/hazard_unit.sv
//
// Handles late-result use, blocking division, and independent bus backpressure.
// A LOAD or multiply in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the producer's rd
// must be stalled by exactly one cycle.
//
// Outputs:
//   stall_if / stall_id : freeze PC / hold ID/EX payload, respectively.
//   flush_if / flush_id : on EX recovery, invalidate the younger fetch.
//   flush_id            : also clears ID/EX validity on late-result use to
//                          inject a single-cycle bubble between producer
//                          and the dependent instruction.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_late_result, // valid LOAD or multiply in EX
  input  logic [4:0] id_ex_rd,          // ID/EX.rd (late producer's dest)
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       redirect,          // advancing EX prediction mismatch
  input  logic       execute_busy,      // hold only the frontend for DIV/REM
  // Bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). When low, the corresponding
  // memory request is NOT serviced this cycle.
  input  logic       imem_ready,
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  output logic       stall_if,          // PC reg holds
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_if,          // IF/ID validity -> 0
  output logic       flush_id,          // ID/EX validity/metadata -> 0
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic late_use_hazard;
  logic imem_stall;
  logic dmem_stall;

  always_comb begin
    // Raw fetch indices and valid-qualified EX late producer only. In particular,
    // IF validity depends on recovery and must not enter this comparison.
    late_use_hazard = id_ex_late_result
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
    imem_stall = !imem_ready;
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // PC reg holds on any stall reason.
    stall_if      = late_use_hazard || imem_stall || dmem_stall || execute_busy;
    // Only validity changes when imem didn't deliver or EX recovers.
    flush_if      = redirect || imem_stall;
    // ID/EX register:
    //   - dmem_stall  -> hold        (preserve in-flight pipeline state)
    //   - execute_busy -> hold       (older MEM/WB stages still advance)
    //   - late_use    -> bubble      (1-cycle stall between producer + use)
    //   - redirect    -> bubble      (kill wrong-path)
    //   - otherwise   -> capture
    // dmem_stall takes precedence over late_use's bubble: re-evaluate
    // late_use next cycle when the bus unblocks. flush_id is 1 only when
    // we want bubble (not hold).
    stall_id      = dmem_stall || late_use_hazard || execute_busy;
    // EX already qualifies redirect with advancement. Recovery has final
    // priority without entering the payload hold enable or hazard decode.
    flush_id      = redirect || (late_use_hazard && !dmem_stall && !execute_busy);
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
