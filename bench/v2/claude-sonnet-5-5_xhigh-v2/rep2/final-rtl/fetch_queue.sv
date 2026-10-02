// rtl/fetch_queue.sv
//
// Decoupled fetch queue between the (BTB-predicted) fetch pc and ID.
// A DEPTH-entry circular buffer (DEPTH = 2**AW) of if_id_t payloads: the
// fetch side writes {pc, instr, prediction} whenever the bus delivers an
// instruction and there is room; the decode side reads the head.
//
// Zero-latency bypass: with the queue empty the incoming fetch entry is
// the head, so a fetch that is consumed in the cycle it arrives never
// touches the queue storage (no extra cycle on the mispredict path).
//
// Write data is unconditional on `fire`; the ID-side stall cone (`pop`)
// only drives the pointers/count, never the data flops.
//
// `flush` (registered EX redirect) drops everything: the whole queue and
// the in-flight fetch are wrong-path. It overrides fire/pop.
//
// Entry storage omits `valid` (implied) and pc[1:0] (always 0: reset pc,
// pc+4, BTB targets and trap-gated redirect targets are all word aligned).
//
// Latency:        0 (bypass) or 1+ cycles (queued).
// RVFI fields:    none (carries pc/instr that RVFI reports at retirement).
module fetch_queue #(
  parameter int AW = 2                       // pointer width, DEPTH = 2**AW
) (
  input  logic     clock,
  input  logic     reset,
  input  logic     flush,                    // drop everything (redir_q)
  input  logic     in_valid,                 // bus delivers `in` this cycle
  input  if_id_t   in,                       // incoming fetch entry
  input  logic     pop,                      // ID takes the head (head_valid && !stall)
  output logic     fire,                     // `in` accepted (fetch pc advances)
  output if_id_t   head                      // head.valid = head valid
);

  localparam int DEPTH = 1 << AW;

  // Entry = {pc[31:2], instr, pred_taken, pred_npc[17:0], pred_hit, pred_ctr}.
  // Flat vectors (not a struct array): Yosys, which riscv-formal runs through,
  // mishandles member-wise assignment into packed-struct memories.
  localparam int EW = 30 + 32 + 1 + 18 + 1 + 2;

  logic [EW-1:0] mem [0:DEPTH-1];
  logic [AW-1:0] wr_ptr;
  logic [AW-1:0] rd_ptr;
  logic [AW:0]   count;

  logic          full;
  logic          empty;
  logic [EW-1:0] in_e;
  logic [EW-1:0] head_e;

  assign full  = count[AW];                  // count == DEPTH
  assign empty = (count == '0);
  assign fire  = in_valid && !flush && !full;

  // in.pc[1:0] and in.valid are not stored.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [1:0] in_pc_lo;
  logic       in_valid_f;
  /* verilator lint_on UNUSEDSIGNAL */
  assign in_pc_lo   = in.pc[1:0];
  assign in_valid_f = in.valid;

  assign in_e = {in.pc[31:2], in.instr, in.pred_taken, in.pred_npc,
                 in.pred_hit, in.pred_ctr};

  always_ff @(posedge clock) begin
    if (fire) mem[wr_ptr] <= in_e;
  end

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;
    end else begin
      if (fire) wr_ptr <= wr_ptr + 1'b1;
      if (pop)  rd_ptr <= rd_ptr + 1'b1;
      count <= count + {{AW{1'b0}}, fire} - {{AW{1'b0}}, pop};
    end
  end

  logic head_valid;

  assign head_e     = empty ? in_e : mem[rd_ptr];
  assign head_valid = (!empty || in_valid) && !flush;

  // NOP-gate a bubble so the hazard unit never sees garbage rs1/rs2.
  always_comb begin
    head.pc         = {head_e[EW-1 -: 30], 2'b00};
    head.instr      = head_valid ? head_e[21 + 32 : 22] : 32'h0000_0013;
    head.valid      = head_valid;
    head.pred_taken = head_e[21];
    head.pred_npc   = head_e[20:3];
    head.pred_hit   = head_e[2];
    head.pred_ctr   = head_e[1:0];
  end

endmodule
