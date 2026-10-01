// rtl/loop_buf.sv
//
// Predictor-steered loop stream buffer (LSB). Hides imem backpressure
// inside short predicted-taken backward loops by replaying the loop body
// from a 16x32 distributed LUT-RAM indexed by pc[5:2].
//
// Trigger: the IF word is a legal BRANCH, predicted taken, with B-imm in
// [-60, -4] (the loop start..branch spans at most 16 words, so pc[5:2]
// never aliases inside one loop).
//
// Modes (cap_q / rep_q one-hot, both 0 = IDLE):
//   CAPTURE : entered on a trigger (PC -> loop start). Every fetched word
//             (imem_ready) is written at pc[5:2]. The PC can only leave
//             an address when it was fetched (stall_if covers !imem_ready
//             while hit_q = 0), so the pass is complete when the loop
//             branch is reached again (cnt == 0).
//   REPLAY  : the loop branch predicted taken at cnt == 0 (from CAPTURE
//             or REPLAY), or a trigger at pc == end_q while full_q (the
//             buffer still holds that loop; the start word of that entry
//             is fetched from imem, hit_q = 0 for it).
// Position tracking: cnt counts the sequential advances left to the loop
// branch. Inside CAPTURE/REPLAY the PC only moves sequentially (cnt - 1)
// or loops back to the start (cnt <= dist_q); any redirect, any other
// predicted taken and a sequential advance past the branch drop to IDLE.
// So pc == start + 4 * (dist_q - cnt) holds throughout and at_end_q
// (cnt == 0) replaces a 30-bit pc compare on the replay path.
//
// Read one cycle early: on every PC advance (!stall_if) the word for the
// next PC is registered into word_q from ridx, formed from flops only:
//   ridx = at_end_q ? start_q : pc[5:2] + 1
// hit_q says word_q is the word at the current PC. word_q / hit_q hold
// while the PC holds. The buffer only ever returns a word previously
// fetched from the same address.
//
// Fetch store merge (fetch_store.sv): in IDLE (lsb_sel = cap_q || rep_q
// = 0) word_q loads the BSRAM store word instead, and a sequential
// advance sets hit_q from store_hit (the store word is the word at
// pc + 4). CAPTURE keeps hit_q = 0, so every captured word still comes
// from imem_data. Redirect / pred clear only the 1-bit hit_q.
//
// Latency:        buffer read registered (1 cycle ahead of use).
// RVFI fields:    none (a replayed word is issued exactly like a fetch).
module loop_buf (
  input  logic        clock,
  input  logic        reset,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] pc,           // IF PC register ([1:0] = 0)
  input  logic [31:0] instr,        // IF word (opcode bit 2, B-imm bits)
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic        pred,         // IF word predicted taken (valid-gated)
  input  logic        redirect,
  input  logic        stall_if,     // PC holds (unless redirect)
  input  logic        imem_ready,
  input  logic [31:0] imem_data,
  input  logic        store_hit,    // fetch store: store_word is at pc + 4
  input  logic [31:0] store_word,
  output logic        hit_q,        // word_q is the word at pc
  output logic [31:0] word_q
);

  // Re-arm REPLAY on re-entry of the loop still held in the buffer
  // (full 30-bit pc == end_q compare, trigger path only).
  localparam bit REARM = 1'b1;

  logic [31:0] mem [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;

  logic        cap_q, rep_q, full_q, at_end_q;
  logic [3:0]  cnt_q, dist_q, start_q;
  logic [29:0] end_q;

  // ── Trigger decode (IF word; pred already implies a legal BRANCH/JAL
  // with imm[1] = 0, and instr[2] = 0 separates BRANCH from JAL) ─────────
  logic [3:0] imm52;        // B-imm[5:2]
  logic       trig;
  logic       eq_end;
  logic       loop_back;
  logic       rearm;
  logic [3:0] ridx;
  logic       lsb_sel;      // word_q from the buffer (else fetch store)
  always_comb begin
    lsb_sel   = cap_q || rep_q;
    imm52     = {instr[25], instr[11:9]};
    // B-imm in [-60, -4]: imm[12:6] all ones (instr[31], instr[7],
    // instr[30:26]) and imm[5:2] != 0.
    trig      = pred && !instr[2] && instr[31] && instr[7] &&
                (&instr[30:26]) && (imm52 != 4'd0);
    eq_end    = REARM && (pc[31:2] == end_q);
    loop_back = (cap_q || rep_q) && at_end_q && pred;
    rearm     = trig && full_q && eq_end;
    ridx      = at_end_q ? start_q : pc[5:2] + 4'd1;
  end

  // ── Buffer: one sync write port (CAPTURE), one async read into word_q ──
  always_ff @(posedge clock) begin
    if (cap_q && imem_ready) mem[pc[5:2]] <= imem_data;
  end

  always_ff @(posedge clock) begin
    if (!stall_if) word_q <= lsb_sel ? mem[ridx] : store_word;
  end

  // ── hit_q: loop-back replay, sequential replay, or a sequential store
  // hit in IDLE. Every taken fetch (pred) and a sequential advance past
  // the loop branch in CAPTURE/REPLAY clear it. ─────────────────────────
  always_ff @(posedge clock) begin
    if (reset || redirect) hit_q <= 1'b0;
    else if (!stall_if)
      hit_q <= loop_back ||
               (!pred && (lsb_sel ? (rep_q && !at_end_q) : store_hit));
  end

  // ── Control ────────────────────────────────────────────────────────────
  always_ff @(posedge clock) begin
    if (reset) begin
      cap_q    <= 1'b0;
      rep_q    <= 1'b0;
      full_q   <= 1'b0;
      at_end_q <= 1'b0;
      cnt_q    <= 4'd0;
      dist_q   <= 4'd0;
      start_q  <= 4'd0;
      end_q    <= 30'd0;
    end else if (redirect) begin
      cap_q <= 1'b0;
      rep_q <= 1'b0;
    end else if (!stall_if) begin
      if (loop_back) begin
        // Loop branch taken back to the start: the whole body is held.
        cap_q    <= 1'b0;
        rep_q    <= 1'b1;
        full_q   <= 1'b1;
        cnt_q    <= dist_q;
        at_end_q <= 1'b0;
      end else if (rearm) begin
        // Same loop branch as the held loop: replay from the next word.
        cap_q    <= 1'b0;
        rep_q    <= 1'b1;
        cnt_q    <= dist_q;
        at_end_q <= 1'b0;
      end else if (trig) begin
        cap_q    <= 1'b1;
        rep_q    <= 1'b0;
        full_q   <= 1'b0;
        end_q    <= pc[31:2];
        start_q  <= pc[5:2] + imm52;
        dist_q   <= 4'd0 - imm52;
        cnt_q    <= 4'd0 - imm52;
        at_end_q <= 1'b0;
      end else if (pred || at_end_q) begin
        // Other taken fetch, or sequential past the loop branch.
        cap_q <= 1'b0;
        rep_q <= 1'b0;
      end else begin
        cnt_q    <= cnt_q - 4'd1;
        at_end_q <= (cnt_q == 4'd1);
      end
    end
  end

endmodule
