// rtl/hazard_unit.sv
//
// Pipeline control for IF(queue) -> ID -> OF -> EX -> MEM -> WB.
//
// Load-use is detected in OF with flop-fed compares only: a LOAD in EX
// (O/X register) produces its data only at the end of MEM (forwarded
// straight into the O/X operand flops from mem_stage), so the instruction
// behind it in OF (D/O register) waits exactly one cycle.
//
// Outputs:
//   stall_id : hold the D/O register (and pop nothing from the fetch queue).
//   flush_id : D/O captures a bubble (registered EX redirect).
//   hold_ox  : hold the O/X register (dmem stall / muldiv busy).
//   bubble_ox: O/X captures a bubble (load-use or redirect, when not held).
//   consume  : ID takes the fetch-queue head this cycle.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       ox_mem_read,       // O/X.ctrl.mem_read (LOAD in EX)
  input  logic [4:0] ox_rd,             // O/X.rd            (LOAD's dest)
  input  logic [4:0] do_rs1,            // D/O.rs1_addr      (instr in OF)
  input  logic [4:0] do_rs2,            // D/O.rs2_addr
  input  logic       head_valid,        // fetch queue head (or bypass) is a real instruction
  input  logic       redirect,          // registered EX mispredict redirect (redir_q)
  // Bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). When low, the memory request is
  // NOT serviced this cycle. (imem backpressure is folded into head_valid.)
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  // A multi-cycle M op (muldiv) is in EX and its result is not ready yet:
  // hold D/O and O/X (EX/MEM takes bubbles, handled in ex_stage).
  input  logic       ex_busy,
  output logic       stall_id,          // D/O register holds (vs. bubble)
  output logic       consume,           // ID pops the fetch-queue head
  output logic       flush_id,          // D/O register captures '0
  output logic       hold_ox,           // O/X register holds
  output logic       bubble_ox,         // O/X register captures a bubble
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic dmem_stall;

  always_comb begin
    load_use_hazard = ox_mem_read
                   && (ox_rd == do_rs1 || ox_rd == do_rs2)
                   && (ox_rd != 5'b0);
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // D/O register: hold on dmem_stall / load-use / muldiv busy; flush on
    // the (first non-stalled) redirect cycle. Flush wins over hold.
    stall_id      = dmem_stall || load_use_hazard || ex_busy;
    flush_id      = redirect && !dmem_stall && !ex_busy;
    // O/X register: hold on dmem_stall / muldiv busy; bubble on load-use
    // (the dependent instruction waits one cycle in OF) and on redirect
    // (kills the wrong-path instruction leaving OF).
    hold_ox       = dmem_stall || ex_busy;
    bubble_ox     = (load_use_hazard || redirect) && !hold_ox;
    // The queue head moves into D/O when it is real and D/O is not held.
    consume       = head_valid && !stall_id;
    // EX/MEM register: holds on dmem_stall (LOAD waits in MEM until the
    // bus delivers).
    stall_ex_mem  = dmem_stall;
    // MEM/WB register: on dmem_stall the previously-retired instruction's
    // data fields stay alive for forwarding, but valid is cleared so we
    // don't double-retire / double-write the regfile.
    hold_mem_wb   = dmem_stall;
  end

endmodule
