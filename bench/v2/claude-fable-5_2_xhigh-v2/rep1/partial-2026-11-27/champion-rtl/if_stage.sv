// rtl/if_stage.sv
//
// Instruction fetch stage, decoupled from the backend by a 2-entry
// prefetch FIFO of {pc, instr} with an empty-bypass.
//
//   - `stall` means "the backend cannot consume the head word this cycle"
//     (load-use bubble, dmem stall, M-unit busy). It no longer contains
//     the imem stall: an imem word that arrives while the backend is
//     blocked is banked in the FIFO, and a later cycle where imem is not
//     ready is covered by the banked word instead of a NOP bubble.
//   - With the FIFO empty the word goes straight to decode (bypass) and is
//     not pushed, so the unstalled core is cycle-for-cycle the old one.
//   - Redirect (EX-resolved branch / JALR) clears the FIFO and loads PC;
//     it overrides everything.
//   - Fetch-time JAL folding: when the accepted live word is a JAL with a
//     4-byte aligned target, PC <= pc + jimm instead of pc + 4, so the next
//     fetched word is already the target. EX does not redirect for an
//     aligned JAL any more. A misaligned JAL is not folded (PC stays
//     linear) and traps in EX exactly as before.
//
// The IF/ID payload (pc + instr + valid) is still *combinational*: FIFO
// head when valid, else the live imem word (NOP when imem did not deliver).
//
// Timing notes:
//   - Only v0/v1 and PC see `redirect`. The FIFO data flops are written
//     with enables built from the valid flops and `stall` alone (their
//     content is don't-care whenever the valid bit ends up 0).
//   - pc + 4 and pc + jimm are two parallel adders selected late by the
//     JAL pre-decode.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // backend cannot consume (load-use / dmem / M-unit busy)
  input  logic              imem_ready,       // imem delivered imem_data for imem_addr this cycle
  input  logic              redirect,         // registered mispredict / JALR redirect from EX
  input  logic [31:0]       redirect_target,
  // PHT training write (all three come from EX-side flops)
  input  logic              pht_we,
  input  logic [7:0]        pht_widx,
  input  logic [1:0]        pht_wdata,
  // Replay-disable pulse (EX/MEM flops): a FENCE / FENCE.I or a store into
  // the code window was seen. Sets the sticky rs_off flop.
  input  logic              rs_kill,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;
  localparam logic [31:0] NOP      = 32'h0000_0013;

  logic [31:0] pc;

  // ── Prefetch FIFO (entry 0 = head) ────────────────────────────────────
  // Invariant: v1 implies v0.
  logic        v0, v1;
  logic [31:0] pc0, pc1;
  logic [31:0] i0,  i1;
  logic        pt0, pt1;     // predicted-taken bit of the banked word
  logic [1:0]  ct0, ct1;     // PHT counter the banked word was read with

  // ── Bimodal PHT: 256 x 2-bit, distributed (LUT) RAM ───────────────────
  // ONE asynchronous read port (pc[9:2]) and one synchronous write port.
  // No reset loop (that would force flops); zero-wait init to 01 (weakly
  // not-taken). The counter read here travels with the instruction, so
  // the training write needs no second read port.
  logic [1:0] pht [0:255] /* synthesis syn_ramstyle = "distributed_ram" */;
  logic [1:0] pht_rd;

  initial begin
    for (int i = 0; i < 256; i++) pht[i] = 2'b01;
  end

  always_ff @(posedge clock) begin
    if (pht_we) pht[pht_widx] <= pht_wdata;
  end

  assign pht_rd = pht[pc[9:2]];

  // ── JAL / branch pre-decode on the live word ──────────────────────────
  // PC is always 4-byte aligned (reset 0, +4, aligned redirect targets,
  // aligned folds), so the target is aligned iff jimm[1] (= instr[21]) is 0
  // for a JAL and iff bimm[1] (= instr[8]) is 0 for a branch.
  logic [31:0] jimm;
  logic [31:0] bimm;
  logic [31:0] fimm;
  logic        jal_fold;
  logic        br_ok;      // legal conditional branch with an aligned target
  logic        br_take;    // ... predicted taken
  logic        steer;
  assign jimm     = {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
                     imem_data[20], imem_data[30:21], 1'b0};
  assign bimm     = {{19{imem_data[31]}}, imem_data[31], imem_data[7],
                     imem_data[30:25], imem_data[11:8], 1'b0};
  assign jal_fold = (imem_data[6:0] == 7'b1101111) && !imem_data[21];
  // funct3 2/3 (instr[14:13] == 01) are reserved: never steer them.
  assign br_ok    = (imem_data[6:0] == 7'b1100011)
                 && (imem_data[14:13] != 2'b01) && !imem_data[8];
  assign br_take  = br_ok && pht_rd[1];
  assign steer    = jal_fold || br_take;
  // JAL (1101111) and BRANCH (1100011) differ in opcode bit 3, so the
  // immediate in front of the single pc+imm adder needs one select bit.
  assign fimm     = imem_data[3] ? jimm : bimm;

  // Next fetch address of an accepted word.
  logic [31:0] pc_nxt;
  assign pc_nxt = (imem_ready && steer) ? (pc + fimm) : (pc + 32'd4);

  // Handshake strobes (assigned in the Handshake block below).
  logic fetch_acc;   // live word is taken (by decode or by the FIFO)
  logic pop;         // decode consumes the FIFO head
  logic push;        // live word goes into the FIFO

  // imem_data is only meaningful when imem delivered: a replayed word (see
  // below) is never a steering word, so both are gated by imem_ready.
  logic        steer_eff;
  logic        br_take_eff;
  assign steer_eff   = imem_ready && steer;
  assign br_take_eff = imem_ready && br_take;

  // ── Sequential next-word predictor (block RAM, untagged) ──────────────
  // Exact address map of the window pc[31:RS_IW+2] == 0: entry i holds
  // {valid, instr[31:2]} of the word at address 4*(i+1). It is read every
  // cycle (no enable) at pc[RS_IW+1:2], so one cycle later the registered
  // output is the word at (previous pc) + 4, i.e. the word at the CURRENT
  // pc iff the previous cycle was a sequential accept.
  //
  // Only non-steering words are stored (low bits 11, not an aligned JAL,
  // not an aligned legal branch), so a hit always means pc <= pc + 4.
  // The replayed word only ever goes into the FIFO data flops, never into
  // the decode bypass.
  //
  // Every qualifier except the valid bit is pre-computed one cycle early
  // and folded into ONE flop (hit_q): sequential accept, window of the
  // next sequential pc, no same-address write in the read cycle, replay
  // not disabled. So the hit is a 2-input AND behind the block-RAM output:
  //   rs_hit = hit_q && rs_out.valid.
`ifdef RISCV_FORMAL
  localparam integer RS_IW = 4;       // keep the BMC state small
`else
  localparam integer RS_IW = 12;      // 4096 words = 16 KB of code
`endif
  localparam integer RS_N  = 1 << RS_IW;

  logic [30:0]      rs_mem [0:RS_N-1] /* synthesis syn_ramstyle = "block_ram" */;
  logic [30:0]      rs_out;
  logic [RS_IW-1:0] rs_idx;
  logic             rs_win;       // current pc inside the window
  logic             rs_store;     // live word may be stored
  logic             w_en_q;
  logic [RS_IW-1:0] w_idx_q;
  logic [30:0]      w_data_q;
  logic             hit_q;        // previous cycle: accepted, pc <= pc + 4,
                                  // and every pre-computed qualifier holds
  logic             rs_off;       // sticky: replay disabled
  logic             rs_hit;
  logic [31:0]      word;         // live word: imem, else the replayed one

  // Zero-fill (valid = 0), no reset loop. Two nested loops because the
  // vendor synthesis caps a single loop at 2000 iterations.
  localparam integer RS_HI = 1 << (RS_IW / 2);
  localparam integer RS_LO = RS_N / RS_HI;
  initial begin
    for (int i = 0; i < RS_HI; i++)
      for (int j = 0; j < RS_LO; j++)
        rs_mem[i * RS_LO + j] = 31'b0;
  end

  assign rs_idx   = pc[RS_IW+1:2];

  // Dedicated, preserved copy of pc[RS_IW+1:2] (identical next-state) that
  // feeds ONLY the block-RAM read-address pins, so the placer can keep it
  // next to the RAM columns without dragging the real pc flops.
  logic [RS_IW-1:0] pc_ra /* synthesis syn_preserve = 1 */;
  always_ff @(posedge clock) begin
    if      (reset)     pc_ra <= RESET_PC[RS_IW+1:2];
    else if (redirect)  pc_ra <= redirect_target[RS_IW+1:2];
    else if (fetch_acc) pc_ra <= pc_nxt[RS_IW+1:2];
  end
  assign rs_win   = (pc[31:RS_IW+2] == '0);
  assign rs_store = (imem_data[1:0] == 2'b11) && !jal_fold && !br_ok;

  always_ff @(posedge clock) begin
    if (w_en_q) rs_mem[w_idx_q] <= w_data_q;
    rs_out <= rs_mem[pc_ra];
  end

  // Registered write: imem_data is the true content of pc whenever
  // imem_ready (also on a wrong path). pc == 0 is never stored (its slot
  // would be index -1).
  //
  // Post-reset invalidation sweep: block-RAM contents survive a reset, and
  // the program may have been replaced meanwhile. After reset the write
  // port walks every entry once writing valid = 0 (training is suppressed
  // and replay is off while swp_busy), so a hit can only ever return a
  // word observed since the last reset. Costs 2^RS_IW cycles without
  // replay after each reset. Under RISCV_FORMAL there is exactly one reset
  // and the array starts zeroed, so the sweep is compiled out (it would
  // otherwise eat the whole BMC window and leave the replay unreachable).
  logic swp_busy;
`ifdef RISCV_FORMAL
  assign swp_busy = 1'b0;
`else
  logic [RS_IW:0] swp_q;            // MSB = sweep finished
  always_ff @(posedge clock) begin
    if (reset)         swp_q <= '0;
    else if (swp_busy) swp_q <= swp_q + 1'b1;
  end
  assign swp_busy = !swp_q[RS_IW];
`endif

  logic [RS_IW-1:0] w_idx_d;
`ifdef RISCV_FORMAL
  assign w_idx_d = rs_idx - 1'b1;
`else
  assign w_idx_d = swp_busy ? swp_q[RS_IW-1:0] : (rs_idx - 1'b1);
`endif

  always_ff @(posedge clock) begin
    if (reset) w_en_q <= 1'b0;
    else       w_en_q <= swp_busy
                      || (imem_ready && rs_win && (rs_idx != '0) && rs_store);
    w_idx_q  <= w_idx_d;
    w_data_q <= {!swp_busy, imem_data[31:2]};
  end

  // pc + 4 stays inside the window, the entry is not being written in
  // this (read) cycle, replay is still enabled next cycle and the
  // post-reset sweep is over: all flop-launched.
  logic ok_d;
  assign ok_d = rs_win && (rs_idx != '1)
             && !(w_en_q && (w_idx_q == rs_idx))
             && !(rs_off || rs_kill) && !swp_busy;

  always_ff @(posedge clock) begin
    if (reset) begin
      hit_q  <= 1'b0;
      rs_off <= 1'b0;
    end else begin
      // sequential accept this cycle AND the qualifier above
      hit_q  <= fetch_acc && !steer_eff && ok_d;
      rs_off <= rs_off || rs_kill;
    end
  end

  assign rs_hit = hit_q && rs_out[30];
  assign word   = imem_ready ? imem_data : {rs_out[29:0], 2'b11};

  // ── Handshake ─────────────────────────────────────────────────────────
  always_comb begin
    fetch_acc = (imem_ready || rs_hit) && !redirect && (!v1 || !stall);
    pop       = v0 && !stall;
    // A word decode takes directly through the bypass is not pushed. A
    // replayed word (imem not ready) never uses the bypass: always pushed.
    push      = fetch_acc && (v0 || stall || !imem_ready);
  end

  // ── PC ────────────────────────────────────────────────────────────────
  // Redirect overrides everything: a branch/JALR in EX may fire on the
  // same cycle as an imem or dmem stall.
  always_ff @(posedge clock) begin
    if      (reset)     pc <= RESET_PC;
    else if (redirect)  pc <= redirect_target;
    else if (fetch_acc) pc <= pc_nxt;
  end

  assign imem_addr = pc;

  // ── FIFO valid bits (the only FIFO state that sees redirect) ──────────
  always_ff @(posedge clock) begin
    if (reset || redirect) begin
      v0 <= 1'b0;
      v1 <= 1'b0;
    end else if (pop) begin
      v0 <= v1 || push;
      v1 <= v1 && push;
    end else begin
      v0 <= v0 || push;
      v1 <= v1 || (v0 && push);
    end
  end

  // ── FIFO data ─────────────────────────────────────────────────────────
  // Entry 0 is rewritten whenever it is empty or being popped: it takes
  // entry 1 if that is valid, else the live word. Entry 1 is rewritten
  // with the live word whenever it is empty or the queue shifts. Whether
  // the written data is meaningful is decided by v0/v1 alone.
  always_ff @(posedge clock) begin
    if (!v0 || !stall) begin
      pc0 <= v1 ? pc1 : pc;
      i0  <= v1 ? i1  : word;
      pt0 <= v1 ? pt1 : br_take_eff;
      ct0 <= v1 ? ct1 : pht_rd;
    end
    if (!v1 || !stall) begin
      pc1 <= pc;
      i1  <= word;
      pt1 <= br_take_eff;
      ct1 <= pht_rd;
    end
  end

  // ── IF/ID payload ─────────────────────────────────────────────────────
  always_comb begin
    // The prediction handed to decode is exactly the one PC was steered
    // with: a live word is only ever captured (by ID/EX or by the FIFO) on
    // a fetch_acc cycle, and the FIFO banks br_take / the counter with it.
    out.pred_taken = v0 ? pt0 : br_take_eff;
    out.pred_ctr   = v0 ? ct0 : pht_rd;
    out.pc    = v0 ? pc0 : pc;
    // NOP only when there is nothing to hand over (FIFO empty and imem did
    // not deliver). `redirect` is deliberately NOT in this mux: whenever
    // redirect=1 the ID/EX register is flushed (flush_id) or held (dmem
    // stall), so it never captures this payload, and the EX instruction
    // is a branch/jump (mem_read=0) so the load-use detector is 0
    // whatever instr shows.
    out.instr = v0 ? i0 : (imem_ready ? imem_data : NOP);
    out.valid = (v0 || imem_ready) && !redirect;
  end

endmodule
