// rtl/hazard_unit.sv
//
// A consumer that needs a pending MEM result in EX waits one cycle.
// A redirect also discards the fetch on the edge the branch leaves EX.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_late_result,
  input  logic [4:0] id_ex_rd,          // producer's destination
  input  logic       depends_on_rd,     // fetch rs1 or rs2 matches the EX destination
  input  logic       redirect,          // EX has resolved a branch/jump
  input  logic       fence_i,           // valid FENCE.I in EX
  input  logic       serialize,         // following DIV/REM or FENCE.I
  input  logic       replay,
  output logic       needs_replay,
  input  logic       div_wait,          // DIV/REM occupies ID/EX
  input  logic       fetch_valid,       // live bus word or exact predictor hit
  input  logic       dmem_stall,        // MEM needs a retry or bus acceptance
  output logic       stall_if,          // PC reg holds
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       bubble_id,         // discard fetch when ID/EX advances
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic imem_stall;

  always_comb begin
    load_use_hazard = id_ex_late_result && depends_on_rd && id_ex_rd != 5'b0;
    imem_stall = !fetch_valid;

    // The PC gives redirect priority over these interlocks.
    // Issuing FENCE.I advanced IF to fence PC+4. Hold that PC and
    // discard its pre-fence fetch on the edge that lets the fence leave EX.
    needs_replay  = load_use_hazard || serialize;
    stall_if      = replay || imem_stall || dmem_stall || div_wait || fence_i;
    stall_id      = dmem_stall || div_wait || replay;
    bubble_id     = redirect || fence_i;
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
