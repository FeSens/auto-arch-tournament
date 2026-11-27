// rtl/hazard_unit.sv
//
// Pipeline stall / flush control.
//
//   load-use : a LOAD in EX produces its data only after MEM, so the
//              instruction in D (IF/ID register) that consumes the LOAD's
//              rd is stalled by one cycle (bubble into ID/EX).
//   ex_busy  : an M-op is waiting for the sequential muldiv unit. PC,
//              IF/ID and ID/EX hold; EX/MEM takes a bubble (in ex_stage).
//   imem / dmem bus stalls. The imem stall is `!have_instr`: if_stage
//              hides a not-ready bus when it has the word from its skid /
//              successor-word table.
//
// Redirect: EX registers flush_q. In the flush cycle the instruction in
// EX is squashed by ex_stage, the instruction in D is wrong-path too and
// is killed here (kill_id), and F fetches the correct path. While flush_q
// is set the instruction in EX is dead, so its load-use match is ignored
// (ex_busy is gated in ex_stage; EX/MEM then holds the branch, so no dmem
// stall): the flush cycle never holds D.
//
// IF/ID register control (if_stage):
//   ifid_en = !hold_id & !load_use   -> capture (valid = have_instr)
// ID/EX register control (id_stage):
//   hold_id            -> hold     (dmem stall / M-op in EX)
//   !hold_id & kill_id -> bubble   (load-use / empty IF/ID / flush)
//   otherwise          -> capture
// Every input is a flop or a bus-ready pin; no late EX net.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_mem_read,    // ID/EX.ctrl.mem_read (LOAD in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       if_id_valid,       // IF/ID holds an instruction
  input  logic       flush_q,           // instructions in D and EX are squashed
  input  logic       ex_busy,           // M-op in EX not finished yet
  input  logic       have_instr,        // F has a valid word this cycle
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up).
  input  logic       ex_mem_mem_op,
  output logic       stall_if,          // PC reg holds
  output logic       ifid_en,           // IF/ID register captures
  output logic       hold_id,           // ID/EX register holds
  output logic       kill_id,           // ID/EX register takes a bubble
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB takes valid = 0
);

  logic load_use_hazard;
  logic imem_stall;
  logic dmem_stall;

  always_comb begin
    load_use_hazard = id_ex_mem_read && !flush_q && if_id_valid
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
    imem_stall = !have_instr;
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // An M-op in EX is not a LOAD, so load_use is already 0 while ex_busy.
    hold_id       = dmem_stall || ex_busy;
    // D advances: IF/ID takes the F word (or valid = 0).
    ifid_en       = !hold_id && !load_use_hazard;
    // PC reg holds on any stall reason (no bubble collapse).
    stall_if      = load_use_hazard || imem_stall || hold_id;
    kill_id       = load_use_hazard || !if_id_valid || flush_q;
    // EX/MEM register: holds on dmem_stall (LOAD waits in MEM until the
    // bus delivers).
    stall_ex_mem  = dmem_stall;
    // MEM/WB register: on dmem_stall valid is cleared so we don't
    // double-retire / double-write the regfile.
    hold_mem_wb   = dmem_stall;
  end

endmodule
