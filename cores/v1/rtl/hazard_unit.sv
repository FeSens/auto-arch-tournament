// rtl/hazard_unit.sv
//
// Detects the only data hazard the textbook 5-stage doesn't cover via
// forwarding: load-use. A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
//
// Outputs:
//   stall_if / stall_id : freeze the PC reg and the IF/ID combinational
//                          payload (cleared by ID's flush input).
//   flush_if / flush_id : on EX redirect (branch mispredict or jump), kill
//                          the in-flight instructions ahead of the target.
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
  input  logic       redirect,          // EX branch mispredict or jump redirect
  // Effective fetch availability from IF. It is high for a live imem word
  // or for a registered replay hit that can stand in for an external stall.
  input  logic       imem_ready,
  input  logic       ex_long_busy,      // EX has a multi-cycle op occupying ID/EX
  // MEM-stage precise wait: live load/nonbufferable store waiting on dmem,
  // or a younger memory operation blocked behind the pending-store slot.
  input  logic       mem_wait,
  output logic       stall_if,          // PC reg holds
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_if,          // IF/ID comb output -> NOP
  output logic       flush_id,          // ID/EX register captures '0
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic imem_stall;

  always_comb begin
    load_use_hazard = id_ex_mem_read
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
    imem_stall = !imem_ready;

    // PC reg holds on any stall reason.
    stall_if      = load_use_hazard || imem_stall || mem_wait || ex_long_busy;
    // IF/ID combinational payload: NOP whenever we wouldn't have a valid
    // instruction this cycle (mispredict/jump recovery, or imem didn't
    // deliver).
    flush_if      = redirect || imem_stall;
    // ID/EX register:
    //   - mem_wait    -> hold        (preserve in-flight pipeline state)
    //   - load_use    -> bubble      (1-cycle stall between LOAD + use)
    //   - redirect    -> bubble      (kill wrong-path)
    //   - otherwise   -> capture
    // mem_wait takes precedence over load_use's bubble: re-evaluate
    // load_use next cycle when the bus unblocks. flush_id is 1 only when
    // we want bubble (not hold).
    stall_id      = mem_wait || load_use_hazard || ex_long_busy;
    flush_id      = (load_use_hazard || redirect) && !mem_wait;
    // EX/MEM register: holds on mem_wait (LOAD waits in MEM until the bus
    // delivers, or a younger memory op waits behind the store slot).
    stall_ex_mem  = mem_wait;
    // MEM/WB register: on mem_wait the previously-retired instruction's
    // data fields stay alive for forwarding (e.g. a held BNE needs the
    // LOAD's load_data via fwd_mem_wb), but valid is cleared so we don't
    // double-retire / double-write the regfile.
    hold_mem_wb   = mem_wait;
  end

endmodule
