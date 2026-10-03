// rtl/branch_predictor.sv
//
// Fetch-time branch predictor driven by the I-cache's fill-time predecode
// hint, so the next-PC loop contains no tag compare, adder, opcode compare or
// bus input:
//   fpc -> {hint RAM read, BHT read (both indexed by fpc[9:2])}
//       -> spec_taken = h_always | h_ret | (h_br & bht_cnt[1])
//          spec_tgt   = h_ret ? ras0 : h_tgt
//
// The hint is tag-independent: when the cache line belongs to another pc
// (miss) the prediction is bogus, and if_stage squashes and repairs it one
// cycle later from registered flags. A prediction that survives to ID/EX
// carries pred_taken / pred_target exactly as before; EX verifies it.
//
//   - JAL                 : always taken.
//   - BRANCH              : taken when the 2-bit BHT counter's MSB is set.
//                           256 x 2-bit saturating counters indexed by
//                           pc[9:2], no reset (LUT-RAM; performance-only).
//   - `ret` (jalr x0,0(x1)): taken, target = top of a 4-entry return-address
//                           stack. Calls (JAL/JALR with rd == x1) push pc+4.
// The static target is pc + J/B-imm from one 19-bit adder (bits [20:2]) that
// sits at the cache WRITE port (fill time), not in the loop. A target is only
// predicted when it is word aligned (imm[1] == 0) and inside the low 1 MiB
// (pc[31:20] == 0 and no wrap out of the adder); otherwise the hint kind is
// "none" and the front end falls through.
//
// The predecode matches the decoder's legality exactly (BRANCH funct3 2/3
// and JALR funct3 != 0 are illegal and never predicted).
//
// RAS push/pop fire only for a fetch that is not held / squashed (`fire`, early
// terms only). They use a predecode of the raw bus word when the bus delivered
// and the cache hint otherwise; neither select depends on the tag compare
// (`hit`). There is no RAS repair on a mispredict (pollution only costs
// performance).
//
// The BHT is updated from EX through a small register stage so the late
// branch compare only has to reach a flop D pin.
//
// Latency:        combinational prediction; BHT write lands 1 cycle after EX.
// RVFI fields:    none (performance only).
module branch_predictor (
  input  logic        clock,
  input  logic        reset,
  // fetch side
  input  logic [31:2] pc,
  input  logic [31:0] instr,         // raw bus word for pc (valid iff bus ready)
  input  logic [31:2] pc_plus4,
  input  logic        fire,          // fetch not held / squashed (early terms only)
  input  logic        bus_ok,        // the bus delivered the word for pc
  // hint read from the cache line addressed by pc (tag independent)
  input  logic        h_always,
  input  logic        h_br,
  input  logic        h_ret,
  input  logic        h_call,
  input  logic [19:2] h_tgt,
  output logic        spec_taken,
  output logic [31:2] spec_tgt,
  output logic [1:0]  bht_cnt,       // counter read for this pc
  // fill-time predecode of the raw bus word (to the cache write port)
  output logic        f_always,
  output logic        f_br,
  output logic        f_ret,
  output logic        f_call,
  output logic [19:2] f_tgt,
  // EX update (branches only)
  input  logic        upd_valid,
  input  logic [7:0]  upd_idx,       // pc[9:2] of the resolved branch
  input  logic        upd_taken,     // resolved direction
  input  logic [1:0]  upd_cnt        // counter carried from fetch
);

  // ── Fill-time predecode of the bus word ───────────────────────────────
  logic is_jal;
  logic is_br;
  logic is_jalr_op;

  always_comb begin
    is_jal     = (instr[6:0] == 7'b1101111);
    is_br      = (instr[6:0] == 7'b1100011) && (instr[14:13] != 2'b01);
    is_jalr_op = (instr[6:0] == 7'b1100111) && (instr[14:12] == 3'b000);
    f_ret      = (instr == 32'h0000_8067);
    f_call     = (is_jal || is_jalr_op) && (instr[11:7] == 5'd1);
  end

  // Static target: pc + imm[20:2]. JAL and BRANCH differ in opcode bit 3
  // (1101111 vs 1100011).
  logic [20:2] imm19;
  logic        tgt_bit1;
  logic [20:2] sum;
  logic        static_ok;

  always_comb begin
    if (instr[3]) begin
      imm19    = {instr[31], instr[19:12], instr[20], instr[30:22]};
      tgt_bit1 = instr[21];
    end else begin
      imm19    = {{8{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:9]};
      tgt_bit1 = instr[8];
    end
    sum       = {1'b0, pc[19:2]} + imm19;
    static_ok = (pc[31:20] == 12'b0) && !sum[20] && !tgt_bit1;

    f_always = static_ok && is_jal;
    f_br     = static_ok && is_br;
    f_tgt    = sum[19:2];
  end

  // ── BHT (no reset: LUT-RAM) ───────────────────────────────────────────
  (* syn_ramstyle = "distributed_ram" *) logic [1:0] bht [0:255];
  assign bht_cnt = bht[pc[9:2]];

  logic       upd_we_q;
  logic [7:0] upd_idx_q;
  logic       upd_taken_q;
  logic [1:0] upd_cnt_q;
  logic [1:0] upd_new;

  always_ff @(posedge clock) begin
    if (reset) upd_we_q <= 1'b0;
    else       upd_we_q <= upd_valid;
    upd_idx_q   <= upd_idx;
    upd_taken_q <= upd_taken;
    upd_cnt_q   <= upd_cnt;
  end

  always_comb begin
    if (upd_taken_q) upd_new = (upd_cnt_q == 2'd3) ? 2'd3 : upd_cnt_q + 2'd1;
    else             upd_new = (upd_cnt_q == 2'd0) ? 2'd0 : upd_cnt_q - 2'd1;
  end

  always_ff @(posedge clock) begin
    if (upd_we_q) bht[upd_idx_q] <= upd_new;
  end

  // ── Return-address stack (top = ras0) ─────────────────────────────────
  logic [31:2] ras0, ras1, ras2, ras3;
  logic        ras_ret;
  logic        ras_call;

  // The bus word predecode is exact whenever the bus delivered (hit or miss,
  // equal to the hint on a hit); otherwise the fetch can only have been a
  // cache hit and the hint is used. The one case with neither (miss and bus
  // stall: replay) pushes/pops from a stale hint, which only pollutes the RAS.
  // Keeping `hit` off these pins keeps the tag compare off the RAS CE/D cone.
  assign ras_ret  = bus_ok ? f_ret  : h_ret;
  assign ras_call = bus_ok ? f_call : h_call;

  always_ff @(posedge clock) begin
    if (reset) begin
      ras0 <= '0;
      ras1 <= '0;
      ras2 <= '0;
      ras3 <= '0;
    end else if (fire) begin
      if (ras_ret) begin
        ras0 <= ras1;
        ras1 <= ras2;
        ras2 <= ras3;
      end else if (ras_call) begin
        ras0 <= pc_plus4;
        ras1 <= ras0;
        ras2 <= ras1;
        ras3 <= ras2;
      end
    end
  end

  // ── Speculative prediction (the fpc loop) ─────────────────────────────
  always_comb begin
    spec_taken = h_always || h_ret || (h_br && bht_cnt[1]);
    spec_tgt   = h_ret ? ras0 : {12'b0, h_tgt};
  end

endmodule
