// rtl/if_stage.sv
//
// Instruction fetch stage (F) of the six-stage pipeline
//   F -> D -> EX -> MEM -> WB   (F and D are split by the IF/ID register
//                                owned by this module).
//
// The PC is always 4-aligned, so only pc[31:2] is a register.
//
// Redirect (retimed): EX registers `flush_q` / `flush_pc_q` in the cycle
// a mispredicted branch / JALR leaves EX, and the fetch address of the
// NEXT cycle is selected at the head of the cycle from flops only:
//
//     fa = flush_q ? flush_pc_q : pc_q
//
// The word fetched in the flush cycle is correct-path and is captured by
// IF/ID normally; the two older wrong-path instructions (in D and in EX)
// are squashed by hazard_unit.kill_id (flush_q) and by ex_stage.
//
// Fetch-cycle steering (from the raw fetched word), only in cycles
// WITHOUT a flush (flush_q = 0, i.e. fa == pc_q):
//   aligned JAL                 -> always followed (fa + J-imm)
//   branch with aligned target  -> followed when the bimodal PHT says so
// In the flush cycle nothing is steered (pred_taken = 0, `fl` = 1).
//
// Stall hiding (all of it in front of the IF/ID register):
//   cur_instr  = imem_ready ? imem_data : nb_instr_q   (select = ready pin)
//   have_instr = imem_ready | use_nb                   (control only)
// nb_instr_q is either
//   - the 1-word skid: the word that was available in a cycle F could not
//     advance (D held / load-use), re-presented the next cycle; or
//   - a successor-word table (NIT) read: 2^AW x {tag, dir, word} LUT-RAM
//     + reset valid flops, indexed by pc_q one cycle AHEAD. Entry of pc P
//     holds the word at P's successor and the direction (pred_taken) by
//     which that successor was reached. The raw read is registered; the
//     hit compare (tag vs prev_fa_q, dir vs nb_tk_q) is done from flops
//     in the use cycle and only feeds have_instr.
// The table is filled from flops (prev_fa_q / nb_tk_q / adv_q) with the
// bus word whenever the previous cycle advanced and the bus is ready.
// It is never invalidated (program text is immutable).
//
// PHT: 512 x 2 distributed RAM, async read by `pc_q`, written from
// EX-registered training flops. Stored value = counter ^ 2'b01.
//
// Latency:        1 cycle (IF/ID register clocked here).
// RVFI fields:    feeds pc_rdata, pc_wdata and insn (via ID/EX/MEM/WB).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // F does not advance (pc holds)
  input  logic              ifid_en,          // D advances: IF/ID captures
  // Registered redirect from EX (mispredict / JALR), valid for one cycle.
  input  logic              flush_q,
  input  logic [29:0]       flush_pc_q,
  // PHT training (EX-registered flops).
  input  logic              bp_we,
  input  logic [8:0]        bp_idx,
  input  logic [1:0]        bp_old,           // entry read at fetch
  input  logic              bp_taken,         // resolved direction
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  output logic              have_instr,       // a valid word is present in F
  output if_id_t  out               // IF/ID register
);

  localparam logic [29:0] RESET_PC = 30'h0000_0000;
  localparam int AW = 8;            // successor-word table: 2^AW entries
  localparam int TW = 30 - AW;      // tag width

  logic [29:0] pc_q;
  logic [29:0] fa /* synthesis syn_keep = 1 */;
  logic [29:0] pc_inc /* synthesis syn_keep = 1 */;
  logic [29:0] fl_inc /* synthesis syn_keep = 1 */;
  logic [29:0] fa_inc;

  // Both +4 legs start at flops and are selected AFTER the incrementers.
  assign fa     = flush_q ? flush_pc_q : pc_q;
  assign pc_inc = pc_q + 30'd1;
  assign fl_inc = flush_pc_q + 30'd1;
  assign fa_inc = flush_q ? fl_inc : pc_inc;

  // ── Bimodal PHT ───────────────────────────────────────────────────────
  logic [1:0] pht [0:511] /* synthesis syn_ramstyle = "distributed_ram" */;
  logic [1:0] pht_rd;
  logic [1:0] bp_cnt;
  logic [1:0] bp_new;

  // Read index = PC flops only. In a flush cycle (fa = flush_pc_q) the
  // entry is stale; fetch does not steer then and ID does not train.
  assign pht_rd = pht[pc_q[8:0]];

  always_comb begin
    bp_cnt = bp_old ^ 2'b01;
    if (bp_taken) bp_new = (bp_cnt == 2'b11) ? 2'b11 : (bp_cnt + 2'b01);
    else          bp_new = (bp_cnt == 2'b00) ? 2'b00 : (bp_cnt - 2'b01);
  end

  always_ff @(posedge clock) begin
    if (bp_we) pht[bp_idx] <= bp_new ^ 2'b01;
  end

  // ── Word select + stall hiding ────────────────────────────────────────
  logic [31:0]   nb_instr_q;   // skid word / registered table word
  logic [TW-1:0] nb_tag_q;     // registered table tag
  logic          nb_dir_q;     // registered table direction
  logic          nb_tk_q;      // pred_taken of the previous cycle
  logic          nb_val_q;     // table read was valid (prev cycle advanced)
  logic          nb_skid_q;    // nb_instr_q is the skid word of this pc
  logic [29:0]   prev_fa_q;    // fetch address of the previous cycle
  logic          adv_q;        // previous cycle advanced
  logic          use_nb;
  logic [31:0]   cur_instr /* synthesis syn_keep = 1 */;

  // Flop-only compare; feeds have_instr (control) and never selects data.
  assign use_nb     = (nb_skid_q ||
                       (nb_val_q && (nb_tag_q == prev_fa_q[29:AW])
                                 && (nb_dir_q == nb_tk_q)))
                      && !flush_q;
  assign have_instr = imem_ready || use_nb;
  // Garbage when !have_instr: never consumed (pc holds, IF/ID valid = 0).
  assign cur_instr  = imem_ready ? imem_data : nb_instr_q;

  // ── Raw pre-decode + parallel target adders ───────────────────────────
  // Must match id_stage / decoder exactly:
  //   JAL    : opcode 1101111, target aligned iff J-imm[1] (= instr[21]) == 0
  //   BRANCH : opcode 1100011, funct3 not 010 / 011, target aligned iff
  //            B-imm[1] (= instr[8]) == 0
  logic        op_jal;
  logic        op_br;
  logic        early_jal /* synthesis syn_keep = 1 */;
  logic        early_br  /* synthesis syn_keep = 1 */;
  logic        pred_taken;
  logic [29:0] imm_j;    // J-imm[31:2]
  logic [29:0] imm_b;    // B-imm[31:2]
  logic [29:0] tgt_j /* synthesis syn_keep = 1 */;
  logic [29:0] tgt_b /* synthesis syn_keep = 1 */;
  logic [29:0] tgt;

  always_comb begin
    op_jal     = (cur_instr[6:0] == 7'b1101111);
    op_br      = (cur_instr[6:0] == 7'b1100011) && (cur_instr[14:13] != 2'b01);
    // No steering in the flush cycle (early flop gate); the PHT bit stays
    // the last AND. An aligned JAL fetched in a flush cycle redirects from
    // EX instead.
    early_jal  = op_jal && !cur_instr[21] && !flush_q;
    early_br   = op_br  && !cur_instr[8]  && !flush_q;
    pred_taken = early_jal || (early_br && pht_rd[1]);

    imm_j = {{12{cur_instr[31]}}, cur_instr[19:12], cur_instr[20],
             cur_instr[30:22]};
    imm_b = {{20{cur_instr[31]}}, cur_instr[7], cur_instr[30:25],
             cur_instr[11:9]};
    tgt_j = fa + imm_j;
    tgt_b = fa + imm_b;
    tgt   = op_jal ? tgt_j : tgt_b;
  end

  always_ff @(posedge clock) begin
    if (reset)      pc_q <= RESET_PC;
    else if (stall) pc_q <= fa;
    else            pc_q <= pred_taken ? tgt : fa_inc;
  end

  assign imem_addr = {fa, 2'b00};

  // ── Successor-word table (NIT) ────────────────────────────────────────
  // {tag[TW-1:0], dir, word[31:0]}
  logic [TW+32:0]     nit [0:(1<<AW)-1]
                      /* synthesis syn_ramstyle = "distributed_ram" */;
  logic [(1<<AW)-1:0] nit_v;
  logic [TW+32:0]     nit_rd;
  logic               nit_rd_v;
  logic               nit_we;

  // Read: indexed by pc_q (flops). Stale in a flush cycle (fa != pc_q):
  // nb_val_q is cleared then.
  assign nit_rd   = nit[pc_q[AW-1:0]];
  assign nit_rd_v = nit_v[pc_q[AW-1:0]];

  // Fill: the previous cycle advanced from prev_fa_q in direction nb_tk_q,
  // so (no flush) the bus word of this cycle is that pc's successor word.
  assign nit_we = adv_q && !flush_q && imem_ready;

  always_ff @(posedge clock) begin
    if (nit_we)
      nit[prev_fa_q[AW-1:0]] <= {prev_fa_q[29:AW], nb_tk_q, imem_data};
  end

  always_ff @(posedge clock) begin
    if (reset)       nit_v <= '0;
    else if (nit_we) nit_v[prev_fa_q[AW-1:0]] <= 1'b1;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      nb_val_q  <= 1'b0;
      nb_skid_q <= 1'b0;
      adv_q     <= 1'b0;
    end else begin
      nb_val_q  <= !stall && nit_rd_v && !flush_q;
      nb_skid_q <=  stall && have_instr;
      adv_q     <= !stall;
    end
    // stall is only the final 2:1 select (skid leg).
    nb_instr_q <= stall ? cur_instr : nit_rd[31:0];
    nb_tag_q   <= nit_rd[TW+32:33];
    nb_dir_q   <= nit_rd[32];
    nb_tk_q    <= pred_taken;
    prev_fa_q  <= fa;
  end

  // ── IF/ID register ────────────────────────────────────────────────────
  // valid is reset; the data fields are clock-enable only. The word
  // fetched in a flush cycle is correct-path and is captured normally.
  if_id_t ifid_q;

  always_ff @(posedge clock) begin
    if (reset)        ifid_q.valid <= 1'b0;
    else if (ifid_en) ifid_q.valid <= have_instr;

    if (ifid_en) begin
      ifid_q.pc         <= {fa, 2'b00};
      ifid_q.pc4        <= {fa_inc, 2'b00};
      ifid_q.tgt        <= {tgt, 2'b00};
      ifid_q.pred_taken <= pred_taken;
      ifid_q.pht        <= pht_rd;
      ifid_q.fl         <= flush_q;
      ifid_q.instr      <= cur_instr;
    end
  end

  assign out = ifid_q;

endmodule
