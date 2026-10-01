// rtl/fetch_store.sv
//
// Decoupled fetch store: a small instruction store that supplies the IF
// word when the word at pc is resident, and a static fetch steer
// (backward branch / JAL predicted taken) off that word.
//
// Four banks selected by address[3:2], each 2^IDX_W entries of
// {valid, tag = addr[19:IDX_W+4], word}, indexed by addr[IDX_W+3:4] and
// inferred as sync-read simple-dual-port block RAMs.
//
//   Fill:  every cycle the bus delivers (imem_ready) and pc < 1 MB,
//          {1, tag(pc), imem_data} -> bank[pc[3:2]][index(pc)]. Address,
//          data and enable are flops (PC, bus word, ready).
//   Steer: the candidate word is predecoded beside fword_q: pt_q (JAL,
//          or a legal BRANCH with instr[31] = 1, target aligned) and its
//          B/J immediate imm_q. steer = pt_q && use_store (flops only);
//          tgt = pc + imm_q. IF moves the PC to tgt on a steer that is
//          not stalled or redirected; EX repairs a wrong steer.
//   Read:  every cycle, the 4-word window at base = steer ? tgt : pc
//          (one word per bank). Bank j reads index(base) +
//          (j < base[3:2]). The select is flop-only (steer), so no
//          stall / redirect reaches a BSRAM address; the target's index
//          and index + 1 are two parallel carry chains from flops
//          (pc + imm_q, pc + imm16_q with imm16_q = imm + 16). The
//          expected tag / in-range bit (shared by all banks) and a
//          per-bank kill (the +1 wrapped the index, or the fill writes
//          the slot being read) are registered alongside.
//   Pick:  next cycle the PC is base or (bsel_q = 0 only) base + 4, and
//          the word IF wants after that is at pc_now + 4*!stall, inside
//          the window. The PC flop bits pick held = bank[pc[3:2]] and
//          next = bank[pc[3:2]+1], and stall is the last 2:1 select into
//          fword_q / hit_q. The pick is masked when it cannot be for the
//          PC: a steer taken now (the PC jumps: 1-cycle blackout), a
//          steer read last cycle that stalled (bsel_q && stall_q: the
//          window is the target's, the PC held), or a redirect.
//   Use:   use_store = hit_q && !red1_q; the store word has priority
//          over the bus. A redirect (or reset) two cycles back is folded
//          into hit_q, one cycle back blocks through red1_q.
//   Collision: a slot read in the same cycle as the fill writes it is
//          killed (kill_q), so SDP collision semantics never matter.
//
// Reset: simulation / formal clear the entries on reset (as reg_file.sv
// does). The synthesis build runs a 2^IDX_W-cycle post-reset sweep that
// writes invalid entries into every bank and blocks fills and hits
// meanwhile; the bus keeps feeding the pipeline.
//
// Latency:        fill visible 2 cycles later; hits unusable for the 2
//                 cycles after a redirect, 1 cycle after a steer.
// RVFI fields:    feeds insn (via the IF word mux in if_stage).
module fetch_store #(
  parameter int IDX_W = 9           // per-bank index width
) (
  input  logic        clock,
  input  logic        reset,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] pc,           // PC flop (pc[1:0] unused)
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [31:0] imem_data,    // bus word at pc
  input  logic        imem_ready,   // bus delivered imem_data this cycle
  input  logic        stall,        // stall_if: PC holds unless redirect
  input  logic        redirect,     // EX redirect: PC <- target
  output logic        fetch_ok,     // IF word valid (bus or store)
  output logic        use_store,    // IF word is the store word
  output logic [31:0] fword,        // store word for pc (fword_q)
  output logic        steer,        // IF word predicted taken (flops)
  output logic [31:0] tgt           // its target pc + imm
);

  localparam int NB     = 4;
  localparam int TAG_LO = IDX_W + 4;
  localparam int TAG_W  = 20 - TAG_LO;
  localparam int ENT_W  = 1 + TAG_W + 32;
  localparam int DEPTH  = 1 << IDX_W;
  localparam int AW     = IDX_W + 2;  // word-address bits: {index, bank}

  // ── Sweep (synthesis only) ────────────────────────────────────────────
  logic             busy;
  logic [IDX_W-1:0] sweep_idx;

`ifdef VERILATOR
  `define FETCH_STORE_RESET
`elsif RISCV_FORMAL
  `define FETCH_STORE_RESET
`elsif FORMAL
  `define FETCH_STORE_RESET
`endif

`ifdef FETCH_STORE_RESET
  assign busy      = 1'b0;
  assign sweep_idx = '0;
`else
  logic [IDX_W:0] sweep_q;   // MSB set = sweep done

  always_ff @(posedge clock) begin
    if (reset)     sweep_q <= '0;
    else if (busy) sweep_q <= sweep_q + 1'b1;
  end

  assign busy      = !sweep_q[IDX_W];
  assign sweep_idx = sweep_q[IDX_W-1:0];
`endif

  // ── Store word, steer predecode, redirect delay ───────────────────────
  logic          hit_q;
  logic          red1_q;
  logic          bsel_q;      // last read was the steer target's window
  logic          stall_q;     // ... and that steer stalled (PC held)
  logic [31:0]   fword_q;
  logic          pt_q;
  logic [20:1]   imm_q;       // B/J immediate of fword_q
  logic [AW-1:0] imm16_q;     // (imm + 16)[AW+1:2]

  // ── Steer target ──────────────────────────────────────────────────────
  // Full target for the PC / tag / in-range, and the {index, bank} bits
  // of the target and of target + 16 as two parallel chains from flops.
  logic [AW-1:0]    t0;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [AW-1:0]    t1;         // t1[1:0] = t0[1:0]
  /* verilator lint_on UNUSEDSIGNAL */
  logic [IDX_W-1:0] tidx0, tidx1;
  logic [1:0]       tbank;

  always_comb begin
    use_store = hit_q && !red1_q;
    steer     = pt_q && use_store;
    tgt       = pc + {{11{imm_q[20]}}, imm_q, 1'b0};
    t0        = pc[AW+1:2] + imm_q[AW+1:2];
    t1        = pc[AW+1:2] + imm16_q;
    tidx0     = t0[AW-1:2];
    tidx1     = t1[AW-1:2];
    tbank     = t0[1:0];
  end

  // ── Write port (fill / sweep) ─────────────────────────────────────────
  logic             fill;
  logic [IDX_W-1:0] idx, idx_inc;
  logic [IDX_W-1:0] waddr;
  logic [ENT_W-1:0] wdata;

  always_comb begin
    fill    = imem_ready && (pc[31:20] == 12'b0) && !busy;
    idx     = pc[TAG_LO-1:4];
    idx_inc = idx + 1'b1;
    waddr   = busy ? sweep_idx : idx;
    wdata   = busy ? '0 : {1'b1, pc[19:TAG_LO], imem_data};
  end

  // ── Expected tag (of the read base) ───────────────────────────────────
  logic [TAG_W-1:0] tag_q;
  logic             inr_q;

  always_ff @(posedge clock) begin
    tag_q <= steer ? tgt[19:TAG_LO] : pc[19:TAG_LO];
    inr_q <= steer ? (tgt[31:20] == 12'b0) : (pc[31:20] == 12'b0);
  end

  // ── Banks ─────────────────────────────────────────────────────────────
  logic [NB-1:0][31:0] word_b;
  logic [NB-1:0]       hit_b;

  for (genvar j = 0; j < NB; j++) begin : g_bank
    localparam logic [1:0] BANK = j;

    // Bank j holds the window word of the next line when j < base[3:2].
    logic             nxt_p, nxt_t;
    logic             fwe;
    logic             we;
    logic [IDX_W-1:0] raddr;
    logic             wrap;
    logic [ENT_W-1:0] rd;
    logic             kill_q;

    always_comb begin
      /* verilator lint_off CMPCONST */   // bank 3: never the next line
      nxt_p = (BANK < pc[3:2]);
      nxt_t = (BANK < tbank);
      /* verilator lint_on CMPCONST */
      fwe   = fill && (pc[3:2] == BANK);
      we    = busy || fwe;
      raddr = steer ? (nxt_t ? tidx1 : tidx0) : (nxt_p ? idx_inc : idx);
      // The +1 wraps the index (next line is in the next tag): miss.
      wrap  = steer ? (nxt_t && (&tidx0)) : (nxt_p && (&idx));
    end

    (* syn_ramstyle = "block_ram" *)
    logic [ENT_W-1:0] mem [0:DEPTH-1];

`ifdef FETCH_STORE_RESET
    always_ff @(posedge clock) begin
      if (reset) begin
        for (int i = 0; i < DEPTH; i++) mem[i] <= '0;
      end else if (we) begin
        mem[waddr] <= wdata;
      end
    end
`else
    always_ff @(posedge clock) begin
      if (we) mem[waddr] <= wdata;
    end
`endif

    always_ff @(posedge clock) begin
      rd <= mem[raddr];
    end

    // Wrap, or the fill writes the slot read this cycle (the held slot
    // of the PC base, or a target slot): miss.
    always_ff @(posedge clock) begin
      kill_q <= wrap || (fwe && (raddr == idx));
    end

    always_comb begin
      word_b[j] = rd[31:0];
      hit_b[j]  = rd[ENT_W-1] && (rd[ENT_W-2:32] == tag_q) && !kill_q;
    end
  end

  // ── Candidate select + steer predecode ────────────────────────────────
  // PC flop bits pick held (the word at pc) and next (pc + 4); each is
  // predecoded (predict-taken, B/J immediate) before stall, the last
  // select.
  logic [1:0]    sel_h, sel_n;
  logic          blk;
  logic          hit_h, hit_n, hit_d;
  logic [31:0]   word_h, word_n, word_d;
  logic          pt_h, pt_n;
  logic [20:1]   imm_h, imm_n;
  logic [AW-1:0] imm16_h, imm16_n;

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic pt_of(input logic [31:0] w);
    logic is_jal, is_br;
    is_jal = (w[6:0] == 7'b1101111);
    is_br  = (w[6:0] == 7'b1100011) && (w[14:13] != 2'b01);
    // Aligned target: imm[1] = w[21] (J) / w[8] (B).
    pt_of  = (is_jal && !w[21]) || (is_br && w[31] && !w[8]);
  endfunction

  function automatic logic [20:1] imm_of(input logic [31:0] w);
    // opcode bit 3: JAL (1101111) vs BRANCH (1100011).
    imm_of = w[3] ? {w[31], w[19:12], w[20], w[30:21]}
                  : {{9{w[31]}}, w[7], w[30:25], w[11:8]};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    sel_h   = pc[3:2];
    sel_n   = pc[3:2] + 2'd1;
    blk     = bsel_q && stall_q;
    hit_h   = hit_b[sel_h];
    hit_n   = hit_b[sel_n] && !steer;
    word_h  = word_b[sel_h];
    word_n  = word_b[sel_n];
    pt_h    = pt_of(word_h);
    pt_n    = pt_of(word_n);
    imm_h   = imm_of(word_h);
    imm_n   = imm_of(word_n);
    imm16_h = imm_h[AW+1:2] + AW'(4);
    imm16_n = imm_n[AW+1:2] + AW'(4);
    hit_d   = (stall ? hit_h : hit_n) && inr_q && !red1_q && !blk;
    word_d  = stall ? word_h : word_n;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      hit_q  <= 1'b0;
      red1_q <= 1'b1;
      bsel_q <= 1'b0;
    end else begin
      hit_q  <= hit_d;
      red1_q <= redirect || busy;
      bsel_q <= steer;
    end
    stall_q <= stall;
    fword_q <= word_d;
    pt_q    <= stall ? pt_h    : pt_n;
    imm_q   <= stall ? imm_h   : imm_n;
    imm16_q <= stall ? imm16_h : imm16_n;
  end

  assign fetch_ok = imem_ready || use_store;
  assign fword    = fword_q;

endmodule
