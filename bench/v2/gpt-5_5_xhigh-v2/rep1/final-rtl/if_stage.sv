// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// Fetched instruction bits stay raw. Flush/redirect/imem stalls are carried
// by `valid`, and ID is responsible for turning invalid entries into bubbles.
// This keeps EX redirect / imem_ready control out of the instruction-bit path
// that feeds decode and load-use comparison.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (load-use)
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  input  logic              redirect_fold_req,
  input  logic [31:0]       redirect_fold_target,
  input  logic              redirect_fold_accept,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [31:0] fetch_pc;

  always_comb begin
    fetch_pc = redirect_fold_req ? redirect_fold_target : pc;
    next_pc  = redirect_fold_accept ? (redirect_fold_target + 32'd4)
             : redirect             ? redirect_target
                                    : (pc + 32'd4);
  end

  // Redirect must override stall: a BRANCH/JAL/JALR in EX may fire
  // redirect on the same cycle as imem_stall or dmem_stall — without
  // this priority the redirect target would be silently dropped, the
  // PC would hold its old (wrong-path) value, and execution would
  // resume on the wrong path once the bus unstalls. Verified by the
  // VexRiscv-binary CoreMark sweep with --istall enabled.
  always_ff @(posedge clock) begin
    if      (reset)                 pc <= RESET_PC;
    else if (redirect_fold_accept)  pc <= redirect_fold_target + 32'd4;
    else if (redirect)              pc <= redirect_target;
    else if (!stall)                pc <= next_pc;
  end

  assign imem_addr = fetch_pc;

  always_comb begin
    out.pc    = fetch_pc;
    out.instr = imem_data;
    out.valid = redirect_fold_accept || (imem_ready && !redirect);
  end

endmodule
