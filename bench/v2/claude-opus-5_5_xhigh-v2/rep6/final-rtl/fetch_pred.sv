// rtl/fetch_pred.sv
//
// Ahead-indexed next-fetch offset predictor.
//
// 64 entries {v, ctr[1:0], tag[3:0], off[15:2]}, zero-initialized. The
// read address is a dedicated index flop idx_q whose D is if_stage's
// syn_keep'd pc_alt (= hold ? pc : pc_reg). pc_alt contains neither the
// branch condition nor the JALR target, so idx_q equals the PC except in
// the cycle after a take / JALR redirect (then it holds the not-taken
// path's address, which is a deterministic function of the fetch path,
// so the same path keeps using the same key).
//
// The entry read at index P predicts the instruction fetched AFTER P:
// hit = v && ctr[1] && tag match. The registered prediction is applied
// by IF one cycle later, as the flop operand of the pc + inc carry chain:
//   inc_q  = (hit && !jump) ? sext(off) : 1
//   pq_q   = hit && !jump        (ID verifies it against the raw bits)
//   pq_off = off
//   pk     = {idx_q, tag-match, ctr, !jump}   (key actually used + snapshot)
// held on `hold` and squashed only by the registered ID/EX jump kill bit
// (the PC is being redirected to a register target). Any table content
// is legal: ID turns a wrong prediction into a 1-bubble redirect.
//
// The write port is driven only from the MEM-side upd_* flops (mem_stage),
// one cycle after the instruction leaves MEM. Nothing EX-side or
// redirect-derived enters this module.
//
// Latency:        lookup 1 cycle ahead of use; write 1 cycle after MEM.
// RVFI fields:    none (performance only).
module fetch_pred (
  input  logic        clock,
  input  logic        reset,
  input  logic        hold,        // PC holds (stall && !jump)
  input  logic        jump,        // ID/EX.ctrl.is_jump kill bit (flop)
  input  logic [11:2] pc_alt,      // if_stage pc_alt (no take / JALR)
  // write port (registered in mem_stage)
  input  logic        we,
  input  logic [5:0]  waddr,
  input  logic [20:0] wdata,       // {v, ctr[1:0], tag[3:0], off[13:0]}
  // registered prediction
  output logic [29:0] inc,         // pc[31:2] increment for the next fetch
  output logic        pq,          // prediction in use for the ID instr
  output logic [13:0] pq_off,      // its offset (imm[15:2])
  output logic [9:0]  pk_idx,      // lookup key used ({tag, index})
  output logic        pk_tm,       // entry valid && tag match
  output logic [1:0]  pk_ctr,      // entry counter snapshot
  output logic        pk_v         // key valid (not squashed by a jump)
);

  logic [20:0] mem [0:63];

  initial begin
    for (int i = 0; i < 64; i++) mem[i] = 21'b0;
  end

  always_ff @(posedge clock) begin
    if (we) mem[waddr] <= wdata;
  end

  logic [9:0]  idx_q;
  logic [20:0] rd;
  logic        tm;
  logic        hit;

  always_ff @(posedge clock) begin
    idx_q <= pc_alt;
  end

  always_comb begin
    rd  = mem[idx_q[5:0]];
    tm  = rd[20] && (rd[17:14] == idx_q[9:6]);
    hit = tm && rd[19];
  end

  logic [29:0] inc_q;
  logic        pq_q;
  logic [13:0] pq_off_q;
  logic [9:0]  pk_idx_q;
  logic        pk_tm_q;
  logic [1:0]  pk_ctr_q;
  logic        pk_v_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      inc_q  <= 30'd1;
      pq_q   <= 1'b0;
      pk_v_q <= 1'b0;
    end else if (!hold) begin
      inc_q  <= (hit && !jump) ? {{16{rd[13]}}, rd[13:0]} : 30'd1;
      pq_q   <= hit && !jump;
      pk_v_q <= !jump;
    end
  end

  always_ff @(posedge clock) begin
    if (!hold) begin
      pq_off_q <= rd[13:0];
      pk_idx_q <= idx_q;
      pk_tm_q  <= tm;
      pk_ctr_q <= rd[19:18];
    end
  end

  assign inc    = inc_q;
  assign pq     = pq_q;
  assign pq_off = pq_off_q;
  assign pk_idx = pk_idx_q;
  assign pk_tm  = pk_tm_q;
  assign pk_ctr = pk_ctr_q;
  assign pk_v   = pk_v_q;

endmodule
