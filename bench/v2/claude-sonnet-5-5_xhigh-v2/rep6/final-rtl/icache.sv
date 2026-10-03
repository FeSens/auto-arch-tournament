// rtl/icache.sv
//
// Direct-mapped, read-only instruction cache (256 lines x 1 word) indexed by
// pc[9:2]. Three flat async-read distributed-RAM arrays share one write port
// (address, enable):
//   tag  : {valid, pc[19:10]}
//   data : the 32-bit instruction
//   hint : fill-time predecode {always, br, ret, call, 18-bit static target}
//
// The hint outputs are tag-INDEPENDENT: they are whatever the addressed line
// holds, so the fetch loop (if_stage / branch_predictor) can use them with no
// tag compare. Only `hit` (tag + valid + range compare) is tag dependent, and
// it is consumed exclusively at flop D / CE pins (F/D flop, RAS, the replay
// and alias-fix flags), never in the next-PC loop. A hint read from a line
// that does not belong to `pc` (hit = 0) is verified and discarded one cycle
// later by if_stage.
//
// Fill: every cycle the bus delivers (fill_valid) the addressed line is
// rewritten with {tag, bus word, hint}. On a hit that writes back the same
// data, so no hit term reaches the write enable; on a miss it allocates the
// line even while F/D is held, so a held fetch is re-fetched as a hit.
//
// Validity: no memory initial values and no per-line valid flops. After
// reset a sweep walks the 256 lines once, clearing the tag word; hit is
// forced 0 for the sweep and the fill port is owned by it. The sweep
// finishes ~256 cycles after reset, long before the CoreMark start marker.
// Fetches whose pc is outside the low 1 MiB are never cached or hit.
//
// Stores are not snooped; FENCE.I stays an architectural NOP.
//
// Latency:        combinational read at pc; write lands at the clock edge.
// RVFI fields:    none (performance only).
module icache (
  input  logic        clock,
  input  logic        reset,
  // read side (fetch pc)
  input  logic [31:2] pc,
  output logic        hit,
  output logic [31:0] data,
  output logic        h_always,
  output logic        h_br,
  output logic        h_ret,
  output logic        h_call,
  output logic [19:2] h_tgt,
  // fill side (bus word for `pc`, valid when the bus delivers)
  input  logic        fill_valid,
  input  logic [31:0] fill_data,
  input  logic        f_always,
  input  logic        f_br,
  input  logic        f_ret,
  input  logic        f_call,
  input  logic [19:2] f_tgt
);

  // ── Reset sweep ───────────────────────────────────────────────────────
  logic [7:0] sw_cnt;
  logic       sweeping;

  always_ff @(posedge clock) begin
    if (reset) begin
      sw_cnt   <= 8'd0;
      sweeping <= 1'b1;
    end else if (sweeping) begin
      sw_cnt   <= sw_cnt + 8'd1;
      if (sw_cnt == 8'hFF) sweeping <= 1'b0;
    end
  end

  // ── Arrays ────────────────────────────────────────────────────────────
  (* syn_ramstyle = "distributed_ram" *) logic [10:0] tag_mem  [0:255];
  (* syn_ramstyle = "distributed_ram" *) logic [31:0] data_mem [0:255];
  (* syn_ramstyle = "distributed_ram" *) logic [21:0] hint_mem [0:255];

  logic        in_range;
  logic        we;
  logic [7:0]  waddr;
  logic [10:0] wtag;

  assign in_range = (pc[31:20] == 12'b0);
  assign we       = sweeping || (fill_valid && in_range);
  assign waddr    = sweeping ? sw_cnt : pc[9:2];
  assign wtag     = sweeping ? 11'b0 : {1'b1, pc[19:10]};

  always_ff @(posedge clock) begin
    if (we) begin
      tag_mem[waddr]  <= wtag;
      data_mem[waddr] <= fill_data;
      hint_mem[waddr] <= {f_always, f_br, f_ret, f_call, f_tgt};
    end
  end

  logic [10:0] rd_tag;
  logic [21:0] rd_hint;

  assign rd_tag  = tag_mem[pc[9:2]];
  assign data    = data_mem[pc[9:2]];
  assign rd_hint = hint_mem[pc[9:2]];

  assign {h_always, h_br, h_ret, h_call, h_tgt} = rd_hint;

  assign hit = !sweeping && rd_tag[10] && (rd_tag[9:0] == pc[19:10]) && in_range;

endmodule
