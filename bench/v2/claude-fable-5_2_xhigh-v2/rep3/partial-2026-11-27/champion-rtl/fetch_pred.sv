// rtl/fetch_pred.sv
//
// Stall-hiding next-fetch word predictor ("fetch replay" table).
//
// A direct-mapped, FULLY tagged table of previously fetched instruction
// words. It is read ONE CYCLE AHEAD and the answer is held in the
// prediction register pw_q = {hit, word}. In a cycle where the
// instruction bus stalls (imem_ready = 0) and pw_q.hit is set, if_stage
// delivers pw_q.word instead of waiting for the bus.
//
// Key = the fetch STATE of if_stage, {skip_q, pc_q[31:2]} (flops only,
// no adder in front of the RAM address or the tag compare). The entry
// stored under a key is the word at that state's NEXT sequential fetch
// address, pc_q + 4 + 4*skip_q (= if_stage's seq_next). The mapping
// key -> address is fixed, the tag is the complete key (index bits are
// implied by the slot), so a hit is never wrong and there is no
// recovery logic. pc[1:0] is always 00 (misaligned targets trap and
// never redirect).
//
// Invariant: pw_hit_q = 1  =>  pw_word_q is the word last fetched from
// the bus at the CURRENT sequential fetch address.
//
// pw_q update (every cycle):
//   redirect / flush           : hit <= 0   (1 flop; no data depends on it)
//   advance  (word consumed)   : pw_q <= table[key]   (word for seq_next)
//   hold, bus delivered        : pw_q <= {1, bus word}  (skid: the retry
//                                after a load-use / dmem stall / divide
//                                needs no bus)
//   hold otherwise             : keep
//
// Fill: key_q remembers the key of the last advance; the next bus word
// delivered at the sequential address is that key's entry. Registered at
// the producing stage (fill_*_q), written the following cycle; tag +
// word + valid are written atomically.
//
// Flush: `flush` (a FENCE / FENCE.I was decoded) clears pw_q.hit at once
// and, through a 2-deep shift register, clears every valid bit and
// drops the fills of the words fetched in the FENCE cycle and the one
// after it.
//
// Storage: tag + word in LUT-RAM (async read, sync write, no reset),
// valid bits in flops (sync clear on reset / flush).
//
// Latency:        look-up 1 cycle ahead of use; fill 2 cycles from fetch
//                 to visible entry.
// RVFI fields:    none directly (supplies insn words identical to the
//                 bus words).
module fetch_pred #(
  parameter int unsigned IDX_W = 8          // 2**IDX_W entries
) (
  input  logic        clock,
  input  logic        reset,
  // fetch state (flops only)
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] pc,           // if_stage pc_q
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic        skip,         // if_stage skip_q
  // prediction-register control
  input  logic        redirect,     // EX redirect this cycle (late)
  input  logic        advance,      // sequential word consumed (valid when !redirect)
  input  logic        flush,        // FENCE decoded this cycle
  // bus handshake of this cycle (fill + skid)
  input  logic        imem_ready,
  input  logic [31:0] imem_data,
  // prediction for the current sequential fetch address
  output logic        pw_hit,
  output logic [31:0] pw_word
);

  localparam int unsigned DEPTH = 1 << IDX_W;
  localparam int unsigned TAG_W = 31 - IDX_W;     // {skip, pc[31:IDX_W+2]}
  localparam int unsigned ENT_W = TAG_W + 32;

  // ── Storage ───────────────────────────────────────────────────────────
  logic [ENT_W-1:0] mem [0:DEPTH-1] /* synthesis syn_ramstyle = "distributed_ram" */;
  logic [DEPTH-1:0] valid_q;

  // ── Look-up key of the current fetch state ────────────────────────────
  // Index: low pc bits, top index bit XOR skip (keeps the (pc, skip=1)
  // entry of a redirect target out of the slot of its (pc, skip=0) twin).
  logic [30:0]      key;
  logic [IDX_W-1:0] idx;
  logic [ENT_W-1:0] ent;
  logic             hit;

  always_comb begin
    key = {skip, pc[31:2]};
    idx = key[IDX_W-1:0];
    idx[IDX_W-1] = key[IDX_W-1] ^ key[30];
    ent = mem[idx];
    hit = valid_q[idx] && (ent[ENT_W-1:32] == key[30:IDX_W]);
  end

  // ── Key of the last advance = key of the word being fetched now ───────
  logic [30:0] key_q;
  logic        key_valid_q;

  always_ff @(posedge clock) begin
    if (reset || redirect) key_valid_q <= 1'b0;
    else if (advance)      key_valid_q <= 1'b1;
    if (advance)           key_q       <= key;
  end

  // ── Fill port (registered at the producing stage) ─────────────────────
  logic             fill_we_q;
  logic [30:0]      fill_key_q;
  logic [31:0]      fill_word_q;
  logic [1:0]       flush_q;
  logic             flush_any;
  logic             wr_en;
  logic [IDX_W-1:0] wr_idx;
  logic [ENT_W-1:0] wr_ent;

  always_comb begin
    flush_any = |flush_q;
    wr_en     = fill_we_q && !flush_any;
    wr_idx    = fill_key_q[IDX_W-1:0];
    wr_idx[IDX_W-1] = fill_key_q[IDX_W-1] ^ fill_key_q[30];
    wr_ent    = {fill_key_q[30:IDX_W], fill_word_q};
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      fill_we_q <= 1'b0;
      flush_q   <= 2'b00;
    end else begin
      // the bus word is the sequential one (not a redirect target) and
      // its key is known
      fill_we_q <= imem_ready && !redirect && key_valid_q;
      flush_q   <= {flush_q[0], flush};
    end
    fill_key_q  <= key_q;
    fill_word_q <= imem_data;
  end

  always_ff @(posedge clock) begin
    if (wr_en) mem[wr_idx] <= wr_ent;
  end

  always_ff @(posedge clock) begin
    if (reset || flush_any) valid_q <= '0;
    else if (fill_we_q)     valid_q[wr_idx] <= 1'b1;
  end

  // ── Prediction register ───────────────────────────────────────────────
  logic        pw_hit_q;
  logic [31:0] pw_word_q;

  always_ff @(posedge clock) begin
    if (reset || redirect || flush || flush_any) pw_hit_q <= 1'b0;
    else if (advance)                            pw_hit_q <= hit;
    else if (imem_ready)                         pw_hit_q <= 1'b1;
  end

  // Data: no reset, no redirect / flush term (don't-care when hit = 0).
  always_ff @(posedge clock) begin
    if (advance)         pw_word_q <= ent[31:0];
    else if (imem_ready) pw_word_q <= imem_data;
  end

  assign pw_hit  = pw_hit_q;
  assign pw_word = pw_word_q;

endmodule
