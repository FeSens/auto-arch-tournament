// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// On flush or redirect, the instruction emitted to ID is forced to NOP
// (`0x00000013` = ADDI x0,x0,0). This prevents the hazard unit from
// observing a real rs1/rs2 from a wrong-path instruction and inserting
// a spurious load-use stall the cycle after a taken branch.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (load-use)
  input  logic              flush,            // emit NOP into ID this cycle
  input  logic              ex_redirect,      // EX has resolved a branch/jump
  input  logic [31:0]       ex_redirect_target,
  input  logic              id_redirect,      // ID-resolved conditional branch
  input  logic [31:0]       id_redirect_target,
  // Direct JAL target or PC+4 for all other opcodes. Conditional branches
  // that are taken are corrected by id_redirect at the same edge.
  input  logic [31:0]       predicted_next_pc,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;

  always_comb begin
    // EX is older and therefore wins if it is recovering while an
    // already-wrong-path conditional branch happens to decode.
    next_pc = ex_redirect ? ex_redirect_target
            : id_redirect ? id_redirect_target
                          : predicted_next_pc;
  end

  // Redirect must override stall: a BRANCH/JAL/JALR in EX may fire
  // redirect on the same cycle as imem_stall or dmem_stall — without
  // this priority the redirect target would be silently dropped, the
  // PC would hold its old (wrong-path) value, and execution would
  // resume on the wrong path once the bus unstalls. Verified by the
  // VexRiscv-binary CoreMark sweep with --istall enabled.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (ex_redirect) pc <= ex_redirect_target;
    else if (id_redirect) pc <= id_redirect_target;
    else if (!stall)   pc <= next_pc;
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc    = pc;
    // The EX branch is already in ID/EX and must kill the current decode
    // payload.  On an ID redirect that payload *is* the resolving branch,
    // so preserve it while the PC advances to its actual successor.
    out.instr = (flush || ex_redirect) ? 32'h0000_0013 : imem_data;
    out.predicted_next_pc = predicted_next_pc;
    out.valid = !(flush || ex_redirect);
  end

endmodule
