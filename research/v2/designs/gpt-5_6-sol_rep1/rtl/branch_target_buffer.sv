// One-entry taken-target instruction replay buffer.
//
// A legal, aligned, taken backward conditional branch starts a fill on a
// miss.  The instruction is captured only when the redirected target fetch
// is accepted by ID.  A later EX-confirmed hit supplies that instruction to
// ID/EX and lets IF resume at target+4.  There is no speculative lookup in
// the instruction-address path.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif

module branch_target_buffer (
  input  logic        clock,
  input  logic        reset,

  input  logic        resolved_valid,
  input  logic [31:0] resolved_target,
  input  logic        resolved_taken_backward,
  input  logic        resolved_advance,

  input  logic        fetch_accept,
  input  logic [31:0] fetch_instr,

  output replay_t     replay,
  output logic [31:0] replay_next_pc
);

  logic        entry_valid_q;
  logic [31:0] entry_target_pc_q;
  logic [31:0] entry_instr_q;

  logic        fill_pending_q;

  logic hit;
  logic eligible_miss;
  always_comb begin
    hit = entry_valid_q
       && resolved_valid
       && resolved_taken_backward
       && resolved_advance
       && (entry_target_pc_q == resolved_target);

    eligible_miss = resolved_valid
                 && resolved_taken_backward
                 && resolved_advance
                 && !hit;

    replay.pc       = entry_target_pc_q;
    replay.instr    = entry_instr_q;
    replay.valid    = hit;
    replay_next_pc  = entry_target_pc_q + 32'd4;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      entry_valid_q     <= 1'b0;
      entry_target_pc_q <= 32'b0;
      entry_instr_q     <= 32'b0;
      fill_pending_q    <= 1'b0;
    end else begin
      // A newer confirmed miss supersedes every part of an older pending
      // fill.  In particular, a coincident fetch acceptance belongs to the
      // old redirect protocol and must never validate beneath the new tag.
      // The invalid resident tag itself holds the replacement target, so a
      // separate pending-target register is unnecessary.
      if (eligible_miss) begin
        entry_valid_q     <= 1'b0;
        entry_target_pc_q <= resolved_target;
        fill_pending_q    <= 1'b1;
      end else if (fill_pending_q && fetch_accept) begin
        // Redirect/flush protocol guarantees the first instruction accepted
        // into ID after a confirmed miss is the redirected target.  Bus and
        // pipeline stalls only delay this handshake, so no PC comparison is
        // needed here.  This arm is deliberately lower priority than a newer
        // miss, preventing stale accepted data from validating under its tag.
        entry_valid_q     <= 1'b1;
        entry_instr_q     <= fetch_instr;
        fill_pending_q    <= 1'b0;
      end
    end
  end

endmodule
