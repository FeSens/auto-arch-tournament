// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the *fetch* PC register and a 2-entry
// decoupled fetch queue (e0 = oldest, e1); the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// Fetch queue: the fresh word {pc, imem_data, pred_raw} is valid iff
// imem_ready. The head presented to ID is e0 when the queue is non-empty
// (v0 is a flop, so the head mux select is flop-driven) and the fresh word
// otherwise. ID consumes the head when !stall_id. A fresh word is accepted
// (PC advances) when it fits in the queue after this cycle's pop; it is
// stored iff the head is not consumed straight from it (v0 | stall_id).
// Dmem / load-use / divide stalls therefore no longer throw away imem
// words, and an imem stall is hidden whenever an entry is buffered.
//
// On redirect the queue is emptied and the instruction emitted to ID is
// forced to NOP (`0x00000013` = ADDI x0,x0,0) with valid = 0; the same NOP
// is emitted when no head is present (imem stall, empty queue).
// head_rs1 / head_rs2 export the *unmasked* head rs fields for the regfile
// read, load-use and bypass compares, keeping `redirect` out of those cones.
//
// Decode-in-fetch prediction: the instruction word is in hand during the
// cycle it is fetched (imem_data is consumed combinationally), so a B-/J-
// type immediate adder on that word steers the NEXT fetch with zero
// bubbles. The target is recomputed from the instruction (no BTB tags or
// targets, no capacity limit, no stale target).
//   - JAL is always predicted taken.
//   - Conditional branches use a 128-entry direct-mapped table of 2-bit
//     saturating counters in the "agree" encoding: the counter says
//     whether the branch agrees with the static backward-taken /
//     forward-not-taken bias, so cold / aliased entries fall back to BTFN.
//   - JALR is never predicted (EX redirects).
//   - A B/J immediate with imm[1] set (misaligned target) is never
//     predicted, so EX's misalign-trap path sees an unpredicted insn.
// EX only validates the 1-bit direction (pred_taken vs actual) and the
// EX redirect remains the last next-PC mux level, so it keeps priority
// over the prediction (reset > redirect > !stall).
//
// BHT training comes from the registered EX/MEM stage one cycle after
// resolution (bht_upd_*), keeping it off the redirect cone.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              flush,            // emit NOP into ID this cycle
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,       // imem_data is valid this cycle
  input  logic              stall_id,         // ID does not consume the head
  // Unmasked head rs fields (regfile / load-use / bypass compares)
  output logic [4:0]        head_rs1,
  output logic [4:0]        head_rs2,
  // BHT training (from the registered EX/MEM stage)
  input  logic              bht_upd_en,       // a valid branch is in EX/MEM
  input  logic [6:0]        bht_upd_idx,      // its pc[8:2]
  input  logic              bht_upd_taken,    // resolved direction
  input  logic              bht_upd_bwd,      // imm[31] of the branch
  // I-cache fill source (registered ID/EX flops): a valid instruction and its pc
  input  logic              wr_valid,
  input  logic [19:2]       wr_pc,
  input  logic [31:0]       wr_instr,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;

  // ── Decode-in-fetch ────────────────────────────────────────────────────
  // is_br excludes the reserved funct3 = 2,3 so it matches decoder.sv's
  // is_branch exactly. imm_b / imm_j match imm_gen.sv (bit 0 is always 0).
  logic        is_jal;
  logic        is_br;
  logic [31:1] imm_b;
  logic [31:1] imm_j;
  logic [31:1] imm_sel;
  logic [31:0] pred_target;
  logic        bias;       // static prediction: backward -> taken
  logic        ctr_hi;     // BHT counter MSB at pc
  logic        dir;
  logic        pred_raw;

  always_comb begin
    is_jal = (imem_data[6:0] == 7'b1101111);
    is_br  = (imem_data[6:0] == 7'b1100011) && (imem_data[14:13] != 2'b01);

    imm_b = {{19{imem_data[31]}}, imem_data[31], imem_data[7],
             imem_data[30:25], imem_data[11:8]};
    imm_j = {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
             imem_data[20], imem_data[30:21]};
    imm_sel = is_jal ? imm_j : imm_b;

    // pc is always word aligned (redirect targets that are not are trapped
    // in EX and never loaded), so a 30-bit add is exact.
    pred_target = {pc[31:2] + imm_sel[31:2], 2'b00};

    bias = imem_data[31];
    dir  = ctr_hi ? bias : ~bias;

    pred_raw = ~imm_sel[1] & (is_jal | (is_br & dir));
  end

  // ── Branch history table (agree encoding) ──────────────────────────────
  logic [1:0] bht [0:127];
  logic [1:0] upd_cur;
  logic [1:0] upd_new;
  logic       upd_agree;

  always_comb begin
    ctr_hi    = bht[pc[8:2]][1];

    upd_cur   = bht[bht_upd_idx];
    upd_agree = (bht_upd_taken == bht_upd_bwd);
    if (upd_agree) upd_new = (upd_cur == 2'b11) ? 2'b11 : upd_cur + 2'd1;
    else           upd_new = (upd_cur == 2'b00) ? 2'b00 : upd_cur - 2'd1;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 128; i++) bht[i] <= 2'b10;
    end else if (bht_upd_en) begin
      bht[bht_upd_idx] <= upd_new;
    end
  end

  // ── Stall-filler I-cache ───────────────────────────────────────────────
  // Read one word ahead from flops: address = pc + 4, read enable = accept_f,
  // so the output register holds the entry for the current pc whenever the
  // last accepted word fell through (ahead_ok). On an imem stall with a hit
  // the cached word is pushed into the queue flops (never into the head mux /
  // imem_data path) and the pc advances to its predicted next pc, using a
  // duplicate of the decode-in-fetch cone on the cache output.
  logic [31:0] ic_data;
  logic        ic_valid;
  logic [6:0]  ic_tag;
  logic        ahead_ok;
  logic        fill_hit;   // cached word for pc is usable (imem_ready = 0)
  logic        fill_acc;   // ... and the queue can take it
  logic        accept_f;   // accept | fill_acc

  logic [31:0] pc4;
  assign pc4 = pc + 32'd4;

  icache u_ic (
    .clock    (clock),
    .wr_en    (wr_valid & ~redirect & ~reset),
    .wr_idx   (wr_pc[12:2]),
    .wr_tag   (wr_pc[19:13]),
    .wr_data  (wr_instr),
    .rd_en    (accept_f),
    .rd_idx   (pc4[12:2]),
    .rd_data  (ic_data),
    .rd_valid (ic_valid),
    .rd_tag   (ic_tag)
  );

  // Decode-in-fetch duplicate on the cached word.
  logic        is_jal_c;
  logic        is_br_c;
  logic [31:1] imm_b_c;
  logic [31:1] imm_j_c;
  logic [31:1] imm_sel_c;
  logic [31:0] pred_target_c;
  logic        dir_c;
  logic        pred_raw_c;

  always_comb begin
    is_jal_c = (ic_data[6:0] == 7'b1101111);
    is_br_c  = (ic_data[6:0] == 7'b1100011) && (ic_data[14:13] != 2'b01);

    imm_b_c = {{19{ic_data[31]}}, ic_data[31], ic_data[7],
               ic_data[30:25], ic_data[11:8]};
    imm_j_c = {{11{ic_data[31]}}, ic_data[31], ic_data[19:12],
               ic_data[20], ic_data[30:21]};
    imm_sel_c = is_jal_c ? imm_j_c : imm_b_c;

    pred_target_c = {pc[31:2] + imm_sel_c[31:2], 2'b00};

    dir_c      = ctr_hi ? ic_data[31] : ~ic_data[31];
    pred_raw_c = ~imm_sel_c[1] & (is_jal_c | (is_br_c & dir_c));
  end

  always_comb begin
    fill_hit = ~imem_ready & ahead_ok & ic_valid & (ic_tag == pc[19:13]);
  end

  // ── Next PC ────────────────────────────────────────────────────────────
  // The filler expression is selected only while imem_ready = 0.
  always_comb begin
    next_pc = imem_ready ? (pred_raw   ? pred_target   : pc4)
                         : (pred_raw_c ? pred_target_c : pc4);
  end

  // ── Fetch queue (e0 = oldest) ──────────────────────────────────────────
  // Entries hold {pc[31:2], instr, pred_taken}. v1 implies v0.
  typedef struct packed {
    logic [29:0] pc;
    logic [31:0] instr;
    logic        pred;
  } fq_t;

  fq_t  e0, e1, fresh, head;
  logic v0, v1;
  logic head_present;
  logic accept;     // fresh word enters the pipeline (PC advances)
  logic store;      // fresh word is written into the queue
  logic store_f;    // store | fill_acc (filler is always written into the queue)
  fq_t  fresh_q;    // fresh word, or the cached filler word when imem stalls
  logic occ;        // queue still non-empty after the pop (before the store)

  always_comb begin
    // Field-wise (Yosys's frontend rejects the '{...} assignment pattern).
    fresh.pc    = pc[31:2];
    fresh.instr = imem_data;
    fresh.pred  = pred_raw;
    head        = v0 ? e0 : fresh;

    // Filler word: same pc, cached instruction, its own prediction.
    fresh_q.pc    = pc[31:2];
    fresh_q.instr = imem_ready ? imem_data  : ic_data;
    fresh_q.pred  = imem_ready ? pred_raw   : pred_raw_c;

    head_present = v0 | imem_ready;
    accept = imem_ready & ~(v1 & stall_id);
    fill_acc = fill_hit & ~(v1 & stall_id);
    accept_f = accept | fill_acc;
    // Bypassed straight into ID unless the head is e0 or ID is stalled.
    store  = accept & (v0 | stall_id);
    // The cached filler never bypasses ID (head mux is unchanged): always stored.
    store_f = store | fill_acc;
    occ    = v1 | (v0 & stall_id);

    head_rs1 = head.instr[19:15];
    head_rs2 = head.instr[24:20];
  end

  always_ff @(posedge clock) begin
    // Valid bits: count n = v0 + v1; n' = n - pop + store (pop = v0 & ~stall_id).
    if (reset || redirect) begin
      v0 <= 1'b0;
      v1 <= 1'b0;
    end else begin
      v0 <= occ | store_f;
      v1 <= (v1 & stall_id) | (occ & store_f);
    end

    // Payload registers need no redirect / reset gating: the valid bits
    // alone make a stale entry unobservable (the head mux selects on v0).
    if (v1 & ~stall_id)      e0 <= e1;      // pop, e1 shifts down
    else if (store_f & ~occ) e0 <= fresh_q; // queue empty after the pop
    if (store_f & occ)       e1 <= fresh_q;
  end

  // Redirect must override stall: a BRANCH/JAL/JALR in EX may fire
  // redirect on the same cycle as an imem or dmem stall — without this
  // priority the redirect target would be silently dropped, the PC would
  // keep its old (wrong-path) value, and execution would resume on the
  // wrong path once the bus unstalls. Redirect also empties the queue.
  //
  // A fresh word that does not fit (queue full and ID stalled) or is not
  // delivered (imem_ready = 0) simply leaves the PC where it is and is
  // re-fetched / re-predicted next cycle.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (accept_f) pc <= next_pc;
  end

  // ahead_ok: the cache output register holds the entry for the current pc.
  // Set when a word is accepted and the pc falls through; cleared on redirect
  // and on a predicted-taken accept; held while the pc (and the read enable)
  // hold.
  always_ff @(posedge clock) begin
    if (reset || redirect) ahead_ok <= 1'b0;
    else if (accept_f)     ahead_ok <= ~(imem_ready ? pred_raw : pred_raw_c);
  end

  assign imem_addr = pc;

  logic emit;
  always_comb begin
    emit           = head_present & ~(flush | redirect);
    out.pc         = {head.pc, 2'b00};
    out.instr      = emit ? head.instr : 32'h0000_0013;
    out.valid      = emit;
    out.pred_taken = emit & head.pred;
  end

endmodule
