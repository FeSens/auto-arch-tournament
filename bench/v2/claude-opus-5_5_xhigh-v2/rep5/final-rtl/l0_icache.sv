// rtl/l0_icache.sv
//
// Fetch cache. Direct-mapped, 2048 entries indexed by pc[12:2], in block
// RAM. The read is synchronous, but its address register is a copy of the
// PC flop: it loads the PC's own D (pc_d) with the PC's own enable (pc_en),
// so the read crosses the clock edge together with the PC and its data is
// ready at the start of the fetch cycle, like an async read indexed by pc_q.
//
// Each 67-bit entry holds {valid, tag = pc[14:13], instr, tgt[31:2],
// jal_ok, br_ok}: the instruction word plus what the IF predictor needs
// from it without an adder (the predicted target pc + imm, computed by the
// IF carry-select adder at fill time; static for a given pc and word, and
// the aligned-JAL / aligned-BRANCH predecode bits). Only PCs below 32 KiB
// (pc[31:15] == 0) are ever filled or hit.
//
// Fill: every cycle the imem bus delivers (we = imem_ready) the word at pc
// is staged in the fill flops (fill_*_q) and written into the RAM one
// cycle later, so the RAM write port hangs off flops only. The word at the
// PC is architecturally correct whenever the bus accepts.
//
// Read-during-write: the block RAM returns undefined data when the write
// and the read address register hit the same address on one edge. That is
// detected after the fact from flops: the cycle after a read was latched
// (rd_fresh_q), the write that fired on the same edge (wr_q / wr_idx_q, a
// one-cycle-delayed copy of the fill port) is compared with the index the
// read latched (pc[12:2]: the PC loads with the read). While the PC holds,
// the read data holds too, and so does that verdict (bad_q). Reset also
// marks the read data bad until the first post-reset read. A bad read is a
// miss.
//
// Contents only ever affect performance: the core's instruction and data
// memories are separate (stores cannot modify code), and a hit returns
// exactly the word/target a fill at the same pc wrote. So FENCE / FENCE.I
// need not clear it.
//
// Latency:        read: address registered with the PC (data valid in
//                 the fetch cycle); write two edges after the fill cycle
//                 (staging flop + RAM write).
// RVFI fields:    feeds insn / pc_rdata indirectly (via IF/ID) on a hit.
module l0_icache (
  input  logic        clock,
  input  logic        reset,
  // Lookup address: the PC flop (tag, range, latched read index) and the
  // PC's own D / enable (the read address register).
  input  logic [31:2] pc,
  input  logic        rd_en,
  input  logic [12:2] rd_idx,
  // fill port (address = pc)
  input  logic        we,
  input  logic [31:0] w_instr,
  input  logic [31:2] w_tgt,
  input  logic        w_jal_ok,
  input  logic        w_br_ok,
  // lookup port (address = pc)
  output logic        hit,
  output logic [31:0] instr,
  output logic [31:2] tgt,
  output logic        jal_ok,
  output logic        br_ok
);

  localparam int IDX_W = 11;                  // pc[12:2]
  localparam int N     = 1 << IDX_W;
  localparam int TAG_W = 2;                   // pc[14:13]
  localparam int W     = 1 + TAG_W + 32 + 30 + 2;

  (* syn_ramstyle = "block_ram" *) logic [W-1:0] mem [0:N-1];

  // Nested: Gowin synthesis caps a single loop at 2000 iterations.
  initial begin
    for (int i = 0; i < N / 32; i++)
      for (int j = 0; j < 32; j++) mem[i * 32 + j] = '0;
  end

  logic             in_range;
  assign in_range = (pc[31:15] == 17'b0);

  // ── Staged fill port ────────────────────────────────────────────────────
  logic             fill_we_q;
  logic [IDX_W-1:0] fill_idx_q;
  logic [TAG_W-1:0] fill_tag_q;
  logic [31:0]      fill_instr_q;
  logic [31:2]      fill_tgt_q;
  logic             fill_jal_q;
  logic             fill_br_q;

  always_ff @(posedge clock) begin
    if (reset) fill_we_q <= 1'b0;
    else       fill_we_q <= we && in_range;
  end

  always_ff @(posedge clock) begin
    fill_idx_q   <= pc[12:2];
    fill_tag_q   <= pc[14:13];
    fill_instr_q <= w_instr;
    fill_tgt_q   <= w_tgt;
    fill_jal_q   <= w_jal_ok;
    fill_br_q    <= w_br_ok;
  end

  always_ff @(posedge clock) begin
    if (fill_we_q)
      mem[fill_idx_q] <= {1'b1, fill_tag_q, fill_instr_q, fill_tgt_q,
                          fill_jal_q, fill_br_q};
  end

  // ── Synchronous read (address register = PC copy) ──────────────────────
  logic [W-1:0] rd_q;

  always_ff @(posedge clock) begin
    if (rd_en) rd_q <= mem[rd_idx];
  end

  // ── Read-during-write / reset guard (flops only) ───────────────────────
  logic             rd_fresh_q;
  logic             wr_q;
  logic [IDX_W-1:0] wr_idx_q;
  logic             bad_q;
  logic             bad;

  always_ff @(posedge clock) begin
    if (reset) begin
      rd_fresh_q <= 1'b0;
      wr_q       <= 1'b0;
      bad_q      <= 1'b1;
    end else begin
      rd_fresh_q <= rd_en;
      wr_q       <= fill_we_q;
      bad_q      <= bad;
    end
    wr_idx_q <= fill_idx_q;
  end

  assign bad = rd_fresh_q ? (wr_q && wr_idx_q == pc[12:2]) : bad_q;

  logic             rd_valid;
  logic [TAG_W-1:0] rd_tag;

  assign {rd_valid, rd_tag, instr, tgt, jal_ok, br_ok} = rd_q;
  assign hit = rd_valid && rd_tag == pc[14:13] && in_range && !bad;

endmodule
