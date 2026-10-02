// rtl/if_stage.sv
//
// Instruction fetch stage: a BTB-driven decoupled fetch front end.
//
// The fetch pc register (fpc, = imem_addr) runs ahead of ID. Each time the
// bus delivers an instruction (imem_ready) and the fetch queue has room, the
// {pc, instr, BTB prediction} bundle is written into fetch_queue and fpc
// advances to the predicted next PC (BTB-predicted-taken target, else
// pc + 4). fpc does NOT depend on any ID-side stall (load-use, dmem stall,
// muldiv busy): fetch keeps filling the queue while ID waits, so the next
// instruction is already there when ID resumes and bus bubbles overlap
// with downstream stalls.
//
// The registered EX redirect (redir_q / redir_tgt_*_q) overrides
// everything: fpc <= redirect_target, the queue is emptied and the
// in-flight fetch is dropped (fire is gated by !redirect). The prediction
// made for each fetch rides down the pipe with it so EX verifies every
// instruction against ITS OWN prediction (wrong-path / aliased entries are
// therefore always safe).
//
// The IF/ID payload is the queue head, or (queue empty) the incoming fetch
// entry via a zero-latency bypass. When there is no valid head (queue empty
// and bus not ready, or redirect pending) the instruction emitted to ID is
// forced to NOP (`0x00000013` = ADDI x0,x0,0) with valid=0, so the hazard
// unit never sees a wrong-path rs1/rs2.
//
// Latency:        fpc update is synchronous; the ID payload is combinational
//                 (queue head mux / bypass).
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              consume,          // ID takes the head this cycle
  input  logic              redirect,         // registered EX mispredict redirect
  input  logic [31:0]       redirect_target,
  // BTB lookup for the current fpc (from btb.sv)
  input  logic              pred_hit,
  input  logic              pred_taken,
  input  logic [17:0]       pred_target,      // predicted next PC [19:2]
  input  logic [1:0]        pred_ctr,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic        fire;
  if_id_t      in_e;

  always_comb begin
    next_pc = pred_taken ? {12'b0, pred_target, 2'b00} : pc + 32'd4;
  end

  // Redirect overrides the (gated-off) fetch advance.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (fire)     pc <= next_pc;
  end

  assign imem_addr = pc;

  // Incoming fetch entry (what the bus delivers for the current fpc).
  always_comb begin
    in_e.pc         = pc;
    in_e.instr      = imem_data;
    in_e.valid      = 1'b1;
    in_e.pred_taken = pred_taken;
    in_e.pred_npc   = pred_target;
    in_e.pred_hit   = pred_hit;
    in_e.pred_ctr   = pred_ctr;
  end

  fetch_queue u_fq (
    .clock      (clock),
    .reset      (reset),
    .flush      (redirect),
    .in_valid   (imem_ready),
    .in         (in_e),
    .pop        (consume),
    .fire       (fire),
    .head       (out)         // out.valid = head valid
  );

endmodule
