// rtl/if_stage.sv
//
// Instruction fetch stage: PC register, BHT/JAL predictor and a decoupled
// predicted-fetch queue.
//
// Fetch queue (depth 4):
//   q0 is the ID-facing head (FD): flops {pc, instr, valid, pred_taken}.
//   Decode, regfile read addresses, forward-select compares and the
//   load-use compare all read q0 straight from flops. q1..q3 is a
//   3-entry shifting FIFO behind it (head always at q0, thermometer valid
//   bits qv[3:0], qv[0] = FD.valid). `pop` (FD consumed by ID, or empty)
//   shifts the queue down.
//
//   The fetch handshake is flop-only: accept = imem_ready && !qv[3]
//   (fewer than three words behind FD). It does NOT depend on pop, so the PC
//   enable is independent of load-use / dmem stall / divider busy. While the
//   backend stalls, the predicted fetch stream keeps running and banks words
//   (up to 4) that would otherwise be thrown away and re-fetched; they fill
//   the bubbles of later imem-not-ready cycles.
//
//   The fetched word (imem_addr = pc) is written at the first free slot after
//   the pop: FD if the queue drains this cycle, else slot n - pop. pred_taken
//   rides with the word; the BHT is trained from EX/MEM as before.
//
// Branch prediction (zero-bubble taken control flow):
//   The raw fetched word is predecoded for JAL (opcode 1101111) and
//   conditional branches (opcode 1100011). JAL is always predicted taken;
//   branches consult a direct-mapped 32 x 2-bit bimodal BHT indexed by
//   pc[6:2] (reset weakly taken, predict taken iff counter[1]). A dedicated
//   adder forms pc + imm_J / imm_B straight from the instruction bits. A
//   prediction is never made when the target is misaligned
//   (target[1:0] != 0) so the EX-stage misalign-trap path is untouched.
//   JALR is never predicted.
//
// Redirect (redirect = redir_q, a flop in ex_stage):
//   All queue valid bits clear. To keep the two-bubble recovery despite the
//   extra FD stage, the fetch address in the redirect cycle is
//   redirect_target (a flop-only 2:1 mux on an output that feeds only the
//   imem port) and the word fetched then is written straight into FD with
//   pc = redirect_target and pred_taken = 0 (no prediction for that single
//   fetch, so redirect_target stays off the BHT index and the pred_target
//   adder); pc <= redirect_target + 4 if imem delivered, else
//   redirect_target.
//
// Latency:        word fetched in cycle t is decoded in ID in cycle t+1
//                 (FD flops), unless it is held in the queue.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              pop,              // FD consumed by ID (or empty)
  input  logic              redirect,         // EX redirect (registered flop)
  input  logic [31:0]       redirect_target,  // its target (flop)
  // BHT training (from the EX/MEM register)
  input  logic              train_en,         // a valid branch sits in EX/MEM
  input  logic [4:0]        train_idx,        // its pc[6:2]
  input  logic              train_taken,      // its resolved direction
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [1:0]  bht [0:31];   // 32 x 2-bit saturating counters

  // ── Predecode of the raw fetched word ─────────────────────────────────
  logic        is_jal;
  logic        is_br;
  logic        bht_taken;
  logic        dir_taken;
  logic [31:0] imm_b;
  logic [31:0] imm_j;
  logic [31:0] pred_off;
  logic [31:0] pred_target;
  logic        pred_taken;

  always_comb begin
    is_jal  = (imem_data[6:0] == 7'b1101111);
    is_br   = (imem_data[6:0] == 7'b1100011);

    bht_taken = bht[pc[6:2]][1];
    dir_taken = is_jal || (is_br && bht_taken);

    imm_b = {{19{imem_data[31]}}, imem_data[31], imem_data[7],
             imem_data[30:25], imem_data[11:8], 1'b0};
    imm_j = {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
             imem_data[20], imem_data[30:21], 1'b0};
    // JAL (1101111) and BRANCH (1100011) differ in opcode bit 3; the
    // offset only matters when dir_taken, i.e. for one of those two.
    pred_off    = imem_data[3] ? imm_j : imm_b;
    pred_target = pc + pred_off;

    pred_taken = dir_taken && (pred_target[1:0] == 2'b00);
  end

  // ── BHT training (read-modify-write on a second read port) ────────────
  logic [1:0] tr_cnt;
  logic [1:0] tr_next;
  always_comb begin
    tr_cnt = bht[train_idx];
    if (train_taken) tr_next = (tr_cnt == 2'b11) ? 2'b11 : tr_cnt + 2'b01;
    else             tr_next = (tr_cnt == 2'b00) ? 2'b00 : tr_cnt - 2'b01;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 32; i++) bht[i] <= 2'b10;   // weakly taken
    end else if (train_en) begin
      bht[train_idx] <= tr_next;
    end
  end

  // ── Fetch queue ───────────────────────────────────────────────────────
  // Entry payload {pc[31:0], instr[31:0], pred_taken}. Flat vectors rather
  // than an array of structs: Yosys (riscv-formal) cannot resolve member
  // selects on struct array elements.
  localparam int ENT_W = 65;

  logic [ENT_W-1:0] q0;      // FD head
  logic [ENT_W-1:0] q1;      // tail, oldest first
  logic [ENT_W-1:0] q2;
  logic [ENT_W-1:0] q3;
  logic [3:0]       qv;      // thermometer valid: qv[i+1] implies qv[i]

  logic             accept;  // the word on imem_data is taken this cycle
  logic [3:0]       apv;     // valid bits after the pop shift
  logic [3:0]       ins;     // one-hot: slot the fetched word is written to
  logic [ENT_W-1:0] w;       // the fetched word

  always_comb begin
    accept = imem_ready && !qv[3];

    apv[0] = pop ? qv[1] : qv[0];
    apv[1] = pop ? qv[2] : qv[1];
    apv[2] = pop ? qv[3] : qv[2];
    apv[3] = !pop && qv[3];

    ins[0] = accept && !apv[0];
    ins[1] = accept && apv[0] && !apv[1];
    ins[2] = accept && apv[1] && !apv[2];
    ins[3] = accept && apv[2] && !apv[3];

    w = {pc, imem_data, pred_taken};
  end

  // FD head: the redirect-cycle word goes straight in (no prediction).
  always_ff @(posedge clock) begin
    if      (redirect) q0 <= {redirect_target, imem_data, 1'b0};
    else if (ins[0])   q0 <= w;
    else if (pop)      q0 <= q1;
  end

  // Tail entries: payload needs no reset or redirect term (valid gates it).
  always_ff @(posedge clock) begin
    if      (ins[1]) q1 <= w;
    else if (pop)    q1 <= q2;
  end

  always_ff @(posedge clock) begin
    if      (ins[2]) q2 <= w;
    else if (pop)    q2 <= q3;
  end

  always_ff @(posedge clock) begin
    if (ins[3]) q3 <= w;
  end

  always_ff @(posedge clock) begin
    if      (reset)    qv <= 4'b0000;
    else if (redirect) qv <= {3'b000, imem_ready};
    else               qv <= apv | ins;
  end

  // ── PC ────────────────────────────────────────────────────────────────
  // pc is the next fetch address. It advances whenever a word is accepted
  // (flop-only condition); redirect wins over everything.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= imem_ready ? (redirect_target + 32'd4) : redirect_target;
    else if (accept)   pc <= pred_taken ? pred_target : (pc + 32'd4);
  end

  assign imem_addr = redirect ? redirect_target : pc;

  always_comb begin
    out.pc         = q0[64:33];
    out.instr      = q0[32:1];
    out.valid      = qv[0];
    out.pred_taken = q0[0];
  end

endmodule
