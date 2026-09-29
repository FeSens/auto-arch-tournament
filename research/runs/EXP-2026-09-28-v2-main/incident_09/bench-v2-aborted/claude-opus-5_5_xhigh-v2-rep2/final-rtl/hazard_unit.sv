// rtl/hazard_unit.sv
//
// Detects the only data hazard the textbook 5-stage doesn't cover via
// forwarding: load-use. A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
//
// Squash is done with valid bits, not by zeroing registers:
//   stall_if  : PC reg holds.
//   id_hold   : ID/EX clock enable (low = capture). Registered-state
//               terms only (dmem stall, mdu stall) — no redirect, no
//               load-use, so the EX branch compare never reaches the
//               ~180 ID/EX data flops.
//   id_squash : ID/EX.valid captures 0 (EX redirect kills the one
//               wrong-path fetch; load-use inserts a 1-cycle bubble while
//               the PC holds and the same instruction is re-presented).
//
// load-use compares against the RAW fetched word. That is safe: a
// redirect and a load-use can never coincide (ID/EX holds either a LOAD
// or a branch/jump), and while imem is stalled the IF slot is invalid
// and the PC holds anyway, so a spurious match only re-captures an
// already-invalid slot.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_valid,       // ID/EX.valid
  input  logic       id_ex_mem_read,    // ID/EX.ctrl.mem_read (LOAD in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  input  logic [4:0] if_id_rs1,         // raw imem_data[19:15]
  input  logic [4:0] if_id_rs2,         // raw imem_data[24:20]
  input  logic       redirect,          // EX has resolved a branch/jump
  // Bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). When low, the corresponding
  // memory request is NOT serviced this cycle.
  input  logic       imem_ready,
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write (valid-qualified
  // at EX/MEM capture).
  input  logic       ex_mem_mem_op,
  // M-op in ID/EX still executing in the multi-cycle MDU (registered
  // state only). Holds PC + ID/EX; ex_stage inserts the EX/MEM bubble.
  input  logic       mdu_stall,
  output logic       stall_if,          // PC reg holds
  output logic       id_hold,           // ID/EX register holds
  output logic       id_squash,         // ID/EX.valid captures 0
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic imem_stall;
  logic dmem_stall;

  always_comb begin
    load_use_hazard = id_ex_valid && id_ex_mem_read
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
    imem_stall = !imem_ready;
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // PC reg holds on any stall reason (redirect overrides in if_stage).
    stall_if      = load_use_hazard || imem_stall || dmem_stall || mdu_stall;
    // ID/EX: hold on dmem_stall (preserve in-flight state; load-use and
    // redirect are re-evaluated when the bus unblocks) and on mdu_stall
    // (M-op waits in ID/EX; it is never a load or a branch/jump, so
    // load-use/redirect can't coincide).
    id_hold       = dmem_stall || mdu_stall;
    id_squash     = load_use_hazard || redirect;
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
