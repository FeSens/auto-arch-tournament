// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// Only instruction-memory unavailability masks the fetched instruction.
// Recovery kills the younger bundle synchronously at ID/EX, avoiding an
// EX-to-instruction-mask-to-decode feedback path.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (load-use)
  input  logic              flush,            // emit NOP into ID this cycle
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  input  logic              predicted_taken,
  input  logic [31:0]       predicted_target,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;

  always_comb begin
    next_pc = predicted_taken ? predicted_target : pc + 32'd4;
  end

  // Accepted EX recovery overrides every front-end stall. Genuine EX
  // holds suppress recovery at its source. Normal prediction advances
  // only on the same edge that ID accepts this fetch and its metadata.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (!stall)   pc <= next_pc;
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc    = pc;
    out.instr = flush ? 32'h0000_0013 : imem_data;
    out.predicted_taken = !flush && predicted_taken;
    out.predicted_target = flush ? 32'b0 : next_pc;
    out.valid = !flush;
  end

endmodule
