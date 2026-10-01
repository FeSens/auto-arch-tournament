// rtl/fetch_store.sv
//
// L0 fetch store: a direct-mapped 1024-word copy of fetched instructions
// in hard BSRAM (1024 x {valid, tag[7:0], word[31:0]}, zero-init =
// invalid). It hides imem backpressure on sequential fetches; its only
// consumer is loop_buf's word_q / hit_q (the fabric register that keeps
// BSRAM clock-to-out off the IF word).
//
// Write port (flops only): every fetch the bus delivers (imem_ready) is
// written at pc[11:2]. The word is the true word at that address, so a
// wrong-path or held-PC write is harmless. The tag stored is that of the
// PREVIOUS word address, (pc - 4)[19:12], so the read side compares it
// with the current PC flop directly (no read-tag register).
//
// Read port, two words ahead: on every PC advance (!stall_if) the array
// registers index pc[11:2] + 2 (PC flop + constant). Invariant: while the
// PC is p and v1_q = 1, DO holds the entry at index(p + 4), i.e. the word
// the next sequential advance needs, and
//   store_hit = v1_q && DO.valid && DO.tag == p[19:12]
// says it is the word at p + 4 (the stored (A - 4) matches p in all of
// pc[19:2]). v1_q is cleared by a redirect or a predicted-taken advance:
// the array was read at the old PC + 8, so the new PC's next word (and
// only that one) falls back to imem; a redirect or predicted target is
// never indexed into the array. The read enable is !stall_if alone
// (redirect never reaches the BSRAM; v1_q covers it), so a held PC holds
// DO. The read index never equals the write index (pc + 8 vs pc).
//
// Latency:        BSRAM read registered two fetches ahead; outputs are
//                 BSRAM DO + one compare, consumed only as flop D inputs.
// RVFI fields:    none (a stored word is issued exactly like a fetch).
module fetch_store (
  input  logic        clock,
  input  logic        reset,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] pc,           // IF PC register ([19:2] used)
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic        imem_ready,
  input  logic [31:0] imem_data,
  input  logic        stall_if,     // PC holds (unless redirect)
  input  logic        redirect,
  input  logic        pred,         // IF word predicted taken
  output logic        store_hit,    // store_word is the word at pc + 4
  output logic [31:0] store_word
);

  logic [40:0] mem [0:1023] /* synthesis syn_ramstyle = "block_ram" */;

  initial begin
    for (int i = 0; i < 1024; i++) mem[i] = '0;
  end

  // ── Write port: imem_ready / pc / imem_data flops only ────────────────
  /* verilator lint_off UNUSEDSIGNAL */
  logic [17:0] wprev;       // (pc - 4)[19:2]; [19:12] is stored
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb wprev = pc[19:2] - 18'd1;

  always_ff @(posedge clock) begin
    if (imem_ready) mem[pc[11:2]] <= {1'b1, wprev[17:10], imem_data};
  end

  // ── Read port: index pc + 8, registered on the PC-advance enable ──────
  logic [9:0]  raddr;
  logic [40:0] rd_q;        // BSRAM read data (DO)
  logic        v1_q;
  always_comb raddr = pc[11:2] + 10'd2;

  always_ff @(posedge clock) begin
    if (!stall_if) rd_q <= mem[raddr];
  end

  always_ff @(posedge clock) begin
    if (reset || redirect) v1_q <= 1'b0;
    else if (!stall_if)    v1_q <= !pred;
  end

  assign store_word = rd_q[31:0];
  assign store_hit  = v1_q && rd_q[40] && (rd_q[39:32] == pc[19:12]);

endmodule
