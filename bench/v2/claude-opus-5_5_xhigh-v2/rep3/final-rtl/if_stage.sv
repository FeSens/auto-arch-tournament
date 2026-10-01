// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register and a 16-entry
// look-ahead BTB; the IF/ID payload (pc + instr + valid + prediction) is
// *combinational* — there is no separate IF/ID flop in this
// microarchitecture, the next-stage's ID/EX register captures everything
// one cycle later.
//
// The raw imem word goes straight to ID with no redirect/flush mux, so
// decode never depends on EX. Wrong-path and imem-stall slots are killed
// by ID's flush (kill bits only); the hazard unit may see a spurious
// load-use on such a slot, which is harmless because redirect overrides
// the PC stall and flush overrides the ID/EX stall.
//
// PC[1:0] is always 0: redirects to misaligned targets are suppressed in
// EX (trap), so the low bits are hardwired.
//
// Look-ahead BTB: 16 entries, direct-mapped, index pc[5:2], tag
// pc[13:6], 18-bit word target pc[19:2] (code lives below 1 MB, so the
// predicted word target is {12'b0, tgt}; a wrong guess is caught by ID's
// pred_off check and replayed), 2-bit counter. 7 x RAM16 LUT-RAM, async
// read, one sync write port driven from EX/MEM training flops.
// The lookup is done one cycle early on npc_seq (the sequential /
// predicted next PC) and registered in cur_q with CE = !stall only; no
// redirect term. redir_q marks "cur_q does not describe pc_w" (the last
// PC load was a redirect) and masks the prediction, so the first fetch
// after a redirect is never predicted (liveness for replays).
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (load-use / bus / div)
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic              redirect_ce,      // same, PC-enable copy
  // redirect_target[1:0] is 0 whenever redirect fires.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]       redirect_target,
  /* verilator lint_on UNUSEDSIGNAL */
  // BTB write port (from EX/MEM flops)
  input  logic              t_we,
  input  logic [3:0]        t_idx,
  input  logic [27:0]       t_wdata,
  output logic              redir,            // redir_q (training outcome)
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [29:0] RESET_PC = 30'h0000_0000;

  logic [29:0] pc_w;

  // ── BTB storage: {tag[7:0], tgt[17:0], ctr[1:0]} ───────────────────────
  (* syn_ramstyle = "distributed_ram" *) logic [27:0] btb_mem [0:15];

`ifdef VERILATOR
  initial begin
    for (int i = 0; i < 16; i++) btb_mem[i] = 28'b0;
  end
`endif

  always_ff @(posedge clock) begin
    if (t_we) btb_mem[t_idx] <= t_wdata;
  end

  // ── Registered prediction for pc_w ─────────────────────────────────────
  logic        pt_q;
  logic        hit_q;
  logic [1:0]  ctr_q;
  logic [17:0] tgt18_q;
  logic        redir_q;
  logic        pt_eff;

  assign pt_eff = pt_q & ~redir_q;

  logic [29:0] inc;
  (* syn_keep = 1 *) logic [29:0] npc_seq;

  always_comb begin
    inc           = pc_w + 30'd1;
    npc_seq[17:0] = pt_eff ? tgt18_q : inc[17:0];
    npc_seq[29:18] = inc[29:18] & {12{~pt_eff}};
  end

  // Lookup of npc_seq (next cycle's fetch address).
  logic [27:0] rd;
  logic        l_hit;

  always_comb begin
    rd    = btb_mem[npc_seq[3:0]];
    l_hit = (rd[27:20] == npc_seq[11:4]);
  end

  // Redirect must override stall: a BRANCH/JAL/JALR in EX may fire
  // redirect on the same cycle as imem_stall or dmem_stall — without
  // this priority the redirect target would be silently dropped, the
  // PC would hold its old (wrong-path) value, and execution would
  // resume on the wrong path once the bus unstalls. Verified by the
  // VexRiscv-binary CoreMark sweep with --istall enabled.
  // redirect_ce is a logically identical copy of redirect that drives
  // only the PC enable; redirect steers the D-mux.
  always_ff @(posedge clock) begin
    if      (reset)                    pc_w <= RESET_PC;
    else if (redirect_ce || !stall)    pc_w <= redirect ? redirect_target[31:2]
                                                        : npc_seq;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      pt_q    <= 1'b0;
      hit_q   <= 1'b0;
      ctr_q   <= 2'b0;
      tgt18_q <= 18'b0;
    end else if (!stall) begin
      pt_q    <= l_hit & rd[1];
      hit_q   <= l_hit;
      ctr_q   <= rd[1:0];
      tgt18_q <= rd[19:2];
    end
  end

  always_ff @(posedge clock) begin
    if (reset) redir_q <= 1'b1;
    else       redir_q <= redirect | (stall & redir_q);
  end

  assign redir     = redir_q;
  assign imem_addr = {pc_w, 2'b00};

  always_comb begin
    out.pc       = {pc_w, 2'b00};
    out.instr    = imem_data;
    out.valid    = 1'b1;
    out.pt       = pt_eff;
    out.hit      = hit_q & ~redir_q;
    out.ctr      = ctr_q;
    out.pred_off = {12'b0, tgt18_q} - pc_w;
  end

endmodule
