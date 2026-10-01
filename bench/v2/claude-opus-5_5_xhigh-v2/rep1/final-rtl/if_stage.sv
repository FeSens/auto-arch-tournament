// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// On an imem stall without a loop-buffer hit, the instruction emitted to
// ID is forced to NOP (`0x00000013` = ADDI x0,x0,0). Redirect is kept off
// this mux (and so off the load-use compare); ID/EX's flush kills the
// wrong-path slot.
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
  // Decode-time prediction of the IF word (branch_pred.sv); pred_target
  // is ID's pc + imm.
  input  logic              pred,
  input  logic [31:0]       pred_target,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  // Loop stream buffer (loop_buf.sv): hit_q = word_q is the word at pc.
  input  logic              lsb_hit,
  input  logic [31:0]       lsb_word,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;

  always_comb begin
    next_pc = pred ? pred_target : pc + 32'd4;
  end

  // Redirect must override stall: a BRANCH/JAL/JALR in EX may fire
  // redirect on the same cycle as imem_stall or dmem_stall — without
  // this priority the redirect target would be silently dropped, the
  // PC would hold its old (wrong-path) value, and execution would
  // resume on the wrong path once the bus unstalls. Verified by the
  // VexRiscv-binary CoreMark sweep with --istall enabled.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (!stall)   pc <= next_pc;
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc    = pc;
    // Redirect does not force a NOP here: flush_id kills the wrong-path
    // slot in ID/EX, and a spurious load-use on it is harmless (a branch
    // or jump in EX is never a LOAD, and redirect overrides stall_if).
    // One LUT4 per bit on four flops (lsb_hit, lsb_word, imem_ready,
    // imem_data): a buffer hit replays the word, else NOP on imem stall.
    out.instr = lsb_hit    ? lsb_word
              : imem_ready ? imem_data : 32'h0000_0013;
    out.valid = lsb_hit || imem_ready;
  end

endmodule
