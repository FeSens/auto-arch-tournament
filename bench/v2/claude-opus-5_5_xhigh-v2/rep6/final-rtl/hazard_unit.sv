// rtl/hazard_unit.sv
//
// Detects the data hazards forwarding cannot cover: a LOAD or a MUL* in
// EX produces its value only at the end of MEM (load data / the EX->MEM
// DSP product), so an instruction immediately behind it that consumes its
// rd is stalled by exactly one cycle (it then picks the value up in ID
// from id_stage's MEM-result bypass, on the cycle MEM completes).
//
// The compare uses the raw IF/ID rs fields: a wrong-path or not-ready
// word may raise a false interlock, which is harmless (redirect overrides
// the PC hold, and flush_id kills ID/EX either way).
//
// Outputs:
//   hold      : PC reg holds (stall_if && !jump: a jump redirect overrides
//               the stall; a taken branch / aligned JALR override it later
//               in the IF PC mux).
//   flush_if  : imem did not deliver; IF/ID valid = 0.
//   stall_id  : ID/EX register holds (dmem stall, or div iterating in EX).
//   flush_id  : narrow kill of ID/EX (valid + side-effect bits only) on a
//               jump in EX or the 1-bubble interlock (taken branches are
//               killed in id_stage from take_kill).
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  // ID/EX.lu_arm = (mem_read | is_mul) && rd != 0, registered in ID
  // (LOAD / MUL* in EX that writes a register).
  input  logic       id_ex_lu_arm,
  input  logic [4:0] id_ex_rd,          // ID/EX.rd
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       id_ex_jump,        // ID/EX.ctrl.is_jump (JAL/JALR in EX)
  // Bus backpressure. When low, the corresponding memory request is NOT
  // serviced this cycle.
  input  logic       imem_ready,
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up).
  input  logic       ex_mem_mem_op,
  // Iterative divider busy in EX (registered state only). Holds PC and
  // ID/EX; ex_stage itself turns the EX/MEM capture into a bubble.
  input  logic       ex_busy,
  output logic       stall_id,
  output logic       flush_if,
  output logic       flush_id,
  output logic       stall_ex_mem,      // EX/MEM register holds (MEM not
                                        // completed: no retire / rf write)
  output logic       hold              // PC holds (stall_if && !jump; a
                                        // jump redirect overrides stall)
);

  logic load_use_hazard;
  logic stall_if;
  logic imem_stall;
  logic dmem_stall;

  always_comb begin
    load_use_hazard = id_ex_lu_arm
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2);
    imem_stall = !imem_ready;
    // dmem stall only matters if there's actually a memory op in EX/MEM.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    stall_if      = load_use_hazard || imem_stall || dmem_stall || ex_busy;
    hold          = stall_if && !id_ex_jump;
    flush_if      = imem_stall;
    // ID/EX register:
    //   - dmem_stall / ex_busy -> hold (whole register, incl. fwd selects)
    //   - load_use / jump      -> narrow kill (bubble)
    //   - otherwise            -> capture
    // A taken branch kills ID/EX too, but that late term is applied in
    // id_stage as the last D-input AND (take_kill, already !dmem_stall).
    // dmem_stall takes precedence over the kill: re-evaluate next cycle.
    // A div in ID/EX can neither redirect nor be a load/mul, so
    // load_use_hazard is already 0 while ex_busy is 1 (a taken branch
    // cannot be in ID/EX either).
    // id_ex_jump is the ID/EX jump kill bit: JALR, unpredicted JAL, or a
    // p_bad instruction (prediction mismatch, redirect to link). A p_bad
    // DIV is a "jump" while it iterates: !ex_busy (register-sourced)
    // keeps the flush from killing it; the PC sits at link meanwhile and
    // the first capture after the div is flushed and refetched.
    stall_id      = dmem_stall || ex_busy;
    flush_id      = (load_use_hazard || (id_ex_jump && !ex_busy)) && !dmem_stall;
    stall_ex_mem  = dmem_stall;
  end

endmodule
