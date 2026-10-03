// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// On flush or redirect, the instruction emitted to ID is forced to NOP
// (`0x00000013` = ADDI x0,x0,0). This keeps a wrong-path / not-delivered
// word from decoding as a real instruction. (The regfile read addresses
// and the load-use compare no longer look at this NOP-substituted word;
// see core.sv / hazard_unit.sv.)
//
// Early redirect (branch prediction, no BTB / RAS):
//   The fetched word is combinational from imem_addr = pc, so IF predecodes
//   it directly. JAL is always predicted taken; a conditional BRANCH is
//   predicted taken when its 2-bit BHT counter (index pc[8:2]) is >= 2.
//   pred_target = pc + J-imm / B-imm. JALR is not predicted. A prediction
//   whose target is not 4-aligned (pred_target[1]) is suppressed, so the PC
//   is always 4-aligned. The BHT is trained only from EX (upd_* ports).
//   EX verifies by DIRECTION only (redirect = actual_taken ^ pred_taken) and
//   there is no target compare: the carried pred_taken bit was produced from
//   the same word and PC EX is executing, so the predicted target always
//   equals EX's own branch/jump target.
//   A predicted redirect only acts when the fetched word is accepted (see the
//   FIFO below); an EX redirect still overrides everything.
//
// 2-entry fetch-ahead FIFO (skid):
//   The PC keeps following the predicted path and every delivered word is
//   either handed to ID straight away (queue empty, ID consumes) or banked
//   in the FIFO (ID does not consume: load-use / dmem stall / MDU busy), so
//   a word that used to be discarded and re-fetched is kept. The fetch
//   ACCEPT term only contains flops and the imem handshake:
//     accept = imem_ready && !redirect && !full
//   (it deliberately ignores a same-cycle pop, so no late hazard signal
//   reaches the PC enable). While the FIFO is non-empty ID decodes the head
//   entry (flops); otherwise it decodes the live imem word. The head is
//   always entry 0 (shift FIFO), so the decode-source select is one flop.
//   A registered EX/MEM redirect clears the FIFO and loads the PC.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              imem_ready,       // imem delivered a word this cycle
  input  logic              stall_id,         // ID does not consume the decode-source word
  input  logic              flush,            // emit NOP into ID this cycle
  input  logic              redirect,         // EX/MEM flop: op in MEM redirects
  input  logic [31:0]       redirect_target,  // EX/MEM flop
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  // Decode-source word (queue head, else the live imem word), NOT NOP-masked:
  // feeds the regfile read addresses, load-use compare and ALU operand preselect.
  output logic [31:0]       raw_instr,
  // A word is available to ID this cycle (queue non-empty or imem delivers).
  output logic              word_avail,
  // BHT training from EX (one update per retiring conditional branch)
  input  logic              upd_en,
  input  logic [6:0]        upd_idx,
  input  logic              upd_taken,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;

  // ── Bimodal BHT: 128 x 2-bit saturating counters ────────────────────────
  // Synchronous reset to weakly-not-taken (2'b01) so cycle counts are
  // deterministic. No update->read bypass: a stale read is only a mispredict.
  // The training bundle from EX is registered here (9 flops) and the
  // read-modify-write happens one cycle later, so the late branch_taken
  // (32-bit compare behind the forward mux) ends at a flop instead of
  // running through the counter update into the BHT write.
  logic [1:0] bht [0:127];
  logic [1:0] bht_upd_old;
  logic [1:0] bht_upd_new;

  logic       upd_en_q;
  logic [6:0] upd_idx_q;
  logic       upd_taken_q;

  always_ff @(posedge clock) begin
    if (reset) upd_en_q <= 1'b0;
    else       upd_en_q <= upd_en;
    upd_idx_q   <= upd_idx;
    upd_taken_q <= upd_taken;
  end

  assign bht_upd_old = bht[upd_idx_q];
  always_comb begin
    if (upd_taken_q) bht_upd_new = (bht_upd_old == 2'b11) ? 2'b11 : bht_upd_old + 2'b01;
    else             bht_upd_new = (bht_upd_old == 2'b00) ? 2'b00 : bht_upd_old - 2'b01;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 128; i++) bht[i] <= 2'b01;
    end else if (upd_en_q) begin
      bht[upd_idx_q] <= bht_upd_new;
    end
  end

  // ── Predecode of the fetched word (opcode + immediate only) ─────────────
  logic        is_jal;
  logic        is_br;
  logic [31:0] imm_j;
  logic [31:0] imm_b;
  logic [31:0] pred_target;
  logic        pred_hit;

  always_comb begin
    is_jal = (imem_data[6:0] == 7'b1101111);
    is_br  = (imem_data[6:0] == 7'b1100011);
    imm_j  = {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
              imem_data[20], imem_data[30:21], 1'b0};
    imm_b  = {{19{imem_data[31]}}, imem_data[31], imem_data[7],
              imem_data[30:25], imem_data[11:8], 1'b0};
    pred_target = pc + (is_jal ? imm_j : imm_b);
    // pc[1:0] == 0 always and imm[0] == 0, so only bit 1 can misalign.
    pred_hit = (is_jal || (is_br && bht[pc[8:2]][1])) && !pred_target[1];
  end

  always_comb begin
    next_pc = pred_hit ? pred_target : pc + 32'd4;
  end

  // ── Fetch-ahead FIFO (2 entries, entry 0 = head) ────────────────────────
  // q_v0 / q_v1 are the valid flops (count 0 / 1 / 2 = !v0 / v0&!v1 / v1).
  logic        q_v0, q_v1;
  logic [29:0] q_pc0, q_pc1;      // pc[31:2] (pc is always 4-aligned)
  logic [31:0] q_in0, q_in1;
  logic        q_pt0, q_pt1;      // pred_taken carried with the word

  // Conservative accept: only flops + the imem handshake (no late signal).
  logic accept;
  assign accept = imem_ready && !redirect && !q_v1;

  // A redirect (EX/MEM flop) overrides everything: PC loads the target and the
  // FIFO is dropped. Otherwise the PC follows the predicted path iff a word is
  // accepted; that word goes straight to ID (queue empty, ID consumes) or is
  // banked (ID does not consume).
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (accept)   pc <= next_pc;
  end

  assign imem_addr = pc;

  always_ff @(posedge clock) begin
    if (reset || redirect) begin
      q_v0 <= 1'b0;
      q_v1 <= 1'b0;
    end else begin
      // v0=0: bank the live word iff it is accepted and ID does not take it.
      // v0=1: stays valid while it is held (stall_id), shifted in from entry 1
      //       (v1), or replaced by the live word (pop + push).
      q_v0 <= q_v0 ? (q_v1 || accept || stall_id) : (accept && stall_id);
      q_v1 <= stall_id && (q_v1 || (accept && q_v0));
    end
  end

  // Entry data flops carry no reset / redirect clear (valid flops gate them).
  always_ff @(posedge clock) begin
    // Tail: written whenever a word is accepted (accept implies !v1, so a
    // valid entry 1 is never overwritten).
    if (accept) begin
      q_pc1 <= pc[31:2];
      q_in1 <= imem_data;
      q_pt1 <= pred_hit;
    end
    // Head: shifted down from entry 1 on a pop, else loaded from the live
    // word (empty queue, or pop + push).
    if (q_v1) begin
      if (!stall_id) begin
        q_pc0 <= q_pc1;
        q_in0 <= q_in1;
        q_pt0 <= q_pt1;
      end
    end else if (accept && (!q_v0 || !stall_id)) begin
      q_pc0 <= pc[31:2];
      q_in0 <= imem_data;
      q_pt0 <= pred_hit;
    end
  end

  // ── Decode source: head entry if non-empty, else the live word ──────────
  assign raw_instr  = q_v0 ? q_in0 : imem_data;
  assign word_avail = q_v0 || imem_ready;

  always_comb begin
    out.pc         = q_v0 ? {q_pc0, 2'b00} : pc;
    out.instr      = (flush || redirect) ? 32'h0000_0013 : raw_instr;
    out.valid      = !(flush || redirect);
    // Bubbles never carry a prediction.
    out.pred_taken = (q_v0 ? q_pt0 : pred_hit) && !(flush || redirect);
  end

endmodule
