// rtl/btb.sv
//
// 32-entry direct-mapped branch target buffer, indexed by pc[6:2], plus a
// 4-entry architectural return-address stack (RAS).
//   - tag    = pc[19:7]       (13b)
//   - target = next_pc[19:2]  (18b)
//   - ctr    = 2-bit saturating taken counter
//   - valid  = plain flops (reset to 0)
//   - is_ret = plain flops: the entry is a function return; fetch predicts
//              it taken to the RAS top instead of the stored target
// Tag+target and counter live in small async-read / sync-write arrays
// (LUT-RAM); the valid / is_ret bits are flops so no array needs a reset.
//
// The lookup is a pure function of the `pc` register and the RAS flops — it
// never looks at imem_data — so the fetch-side prediction stays off the
// instruction-decode cone. Every prediction is verified in EX (the JALR
// compare covers returns), so aliased/stale hits, a stale RAS top (the call
// has not left EX yet when the return is fetched) and the formal flow's
// symbolic imem only cost a redirect, never correctness.
//
// Training comes from EX when a direct branch / JAL / return advances: a
// taken CTI (re)writes tag/target and bumps the counter (allocating at 2, or
// 3 for JAL/JALR); a not-taken CTI that hit at fetch decrements the counter.
// A return allocates with is_ret=1 and a don't-care target (it never needs
// the JALR sum). The hit/counter observed at fetch are carried down the pipe
// and handed back here so no second read port is needed.
//
// The RAS is architectural: it is pushed / popped only by instructions that
// advance out of EX (always correct-path), so it needs no checkpointing or
// repair. It is a shift stack, ras_q[0] is the top, so the fetch-side read
// is a plain flop.
//
// Latency:        lookup combinational; update 2 cycles (the training request
//                 is registered, then written synchronously).
// RVFI fields:    none (prediction only).
module btb (
  input  logic        clock,
  input  logic        reset,
  // lookup (fetch pc register)
  input  logic [19:2] pc,
  output logic        pred_hit,
  output logic        pred_taken,
  output logic [17:0] pred_target,
  output logic [1:0]  pred_ctr,
  // training (EX, only when the CTI advances)
  input  logic        tr_en,       // direct branch / JAL / return leaving EX
  input  logic [19:2] tr_pc,
  input  logic        tr_taken,
  input  logic        tr_is_jal,
  input  logic        tr_is_ret,
  input  logic [17:0] tr_target,
  input  logic        tr_hit,      // hit/ctr observed at fetch
  input  logic [1:0]  tr_ctr,
  // RAS update (EX, only when the instruction advances)
  input  logic        ras_push,
  input  logic        ras_pop,
  input  logic [19:2] ras_push_addr
);

  localparam int IW = 5;             // index bits: pc[IW+1:2]
  localparam int N  = 1 << IW;
  localparam int TW = 18 - IW;       // tag bits:   pc[19:IW+2]

  logic [TW+17:0] tt_arr [0:N-1];  // {tag, target[17:0]}
  logic [1:0]   ctr_arr [0:N-1];
  logic [N-1:0] valid_q;
  logic [N-1:0] is_ret_q;

  // ── Return-address stack ───────────────────────────────────────────────
  logic [17:0] ras_q [0:3];        // [0] = top
  logic [2:0]  ras_cnt;            // 0..4, saturating

  always_ff @(posedge clock) begin
    if (ras_push) begin
      ras_q[0] <= ras_push_addr;
      ras_q[1] <= ras_q[0];
      ras_q[2] <= ras_q[1];
      ras_q[3] <= ras_q[2];
    end else if (ras_pop && ras_cnt != 3'd0) begin
      ras_q[0] <= ras_q[1];
      ras_q[1] <= ras_q[2];
      ras_q[2] <= ras_q[3];
    end
  end

  always_ff @(posedge clock) begin
    if (reset)         ras_cnt <= 3'd0;
    else if (ras_push) ras_cnt <= (ras_cnt == 3'd4) ? 3'd4 : ras_cnt + 3'd1;
    else if (ras_pop && ras_cnt != 3'd0) ras_cnt <= ras_cnt - 3'd1;
  end

  // ── Lookup ─────────────────────────────────────────────────────────────
  logic [IW-1:0] idx;
  logic [TW+17:0] tt_rd;
  logic [1:0]    ctr_rd;
  logic          ret_rd;

  assign idx    = pc[IW+1:2];
  assign tt_rd  = tt_arr[idx];
  assign ctr_rd = ctr_arr[idx];
  assign ret_rd = is_ret_q[idx];

  assign pred_hit    = valid_q[idx] && (tt_rd[TW+17:18] == pc[19:IW+2]);
  assign pred_ctr    = ctr_rd;
  assign pred_taken  = pred_hit && (ret_rd || ctr_rd[1]);
  assign pred_target = ret_rd ? ras_q[0] : tt_rd[17:0];

  // ── Training ───────────────────────────────────────────────────────────
  // The training request is registered first: tr_en / tr_taken depend on the
  // late EX branch compare, and fanning that out to the 32-entry write
  // decode (tt/ctr arrays, valid_q, is_ret_q) put the compare on the
  // critical path. A BTB update therefore lands one cycle after the CTI
  // leaves EX; every prediction is verified in EX, so the late update only
  // costs (at most) a mispredict on a back-to-back re-fetch.
  logic          tr_en_q;
  logic [19:2]   tr_pc_q;
  logic          tr_taken_q;
  logic          tr_is_jal_q;
  logic          tr_is_ret_q;
  logic [17:0]   tr_target_q;
  logic          tr_hit_q;
  logic [1:0]    tr_ctr_q;

  always_ff @(posedge clock) begin
    if (reset) tr_en_q <= 1'b0;
    else       tr_en_q <= tr_en;
  end

  always_ff @(posedge clock) begin
    tr_pc_q     <= tr_pc;
    tr_taken_q  <= tr_taken;
    tr_is_jal_q <= tr_is_jal;
    tr_is_ret_q <= tr_is_ret;
    tr_target_q <= tr_target;
    tr_hit_q    <= tr_hit;
    tr_ctr_q    <= tr_ctr;
  end

  logic [IW-1:0] tr_idx;
  logic          wr_tt;
  logic          wr_ctr;
  logic [1:0]    ctr_d;

  assign tr_idx = tr_pc_q[IW+1:2];
  assign wr_tt  = tr_en_q && tr_taken_q;
  assign wr_ctr = tr_en_q && (tr_taken_q || tr_hit_q);

  always_comb begin
    if (tr_taken_q)
      ctr_d = tr_hit_q ? ((tr_ctr_q == 2'd3) ? 2'd3 : tr_ctr_q + 2'd1)
                       : (tr_is_jal_q ? 2'd3 : 2'd2);
    else
      ctr_d = (tr_ctr_q == 2'd0) ? 2'd0 : tr_ctr_q - 2'd1;
  end

  always_ff @(posedge clock) begin
    if (wr_tt)  tt_arr[tr_idx]  <= {tr_pc_q[19:IW+2], tr_target_q};
    if (wr_ctr) ctr_arr[tr_idx] <= ctr_d;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      valid_q  <= '0;
    end else if (wr_tt) begin
      valid_q[tr_idx] <= 1'b1;
    end
  end

  // is_ret needs no reset: it only matters where valid is set, and every
  // write of valid_q is accompanied by a write of is_ret_q.
  always_ff @(posedge clock) begin
    if (wr_tt) is_ret_q[tr_idx] <= tr_is_ret_q;
  end

endmodule
