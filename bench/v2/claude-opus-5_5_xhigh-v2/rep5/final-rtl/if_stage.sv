// rtl/if_stage.sv
//
// Instruction fetch: the F stage (PC register, branch predictor, 2K-entry
// block-RAM fetch cache) and the registered IF/ID stage that feeds ID.
//
// F: the fetch word comes from the imem bus when it is ready, otherwise
// from the fetch cache (l0_icache.sv) on a hit. The cache's read address
// register loads the PC's own D / enable, so its data is ready at the
// start of the fetch cycle. The source select is imem_ready itself (a flop
// in every bench), so the imem-side predictor path only gains one final
// mux, and the cache side has no adder (the cache stores the predicted
// target). fetch_ok = imem_ready | l0_hit.
//
// IF/ID: a real register, so ID's decoder / regfile addresses / hazard
// compares all start from flops and the L0 read never lands on the decode
// cone. It captures whenever it is empty or the back end moves
// (accept = !valid_q || !backend_stall), so an empty IF/ID fills while the
// back end is frozen.
//
// Registered redirect with fetch override: an EX redirect (mispredict /
// JALR) only sets the ovr_q flop and captures its target in ovr_tgt_q; the
// PC, IF/ID and ID/EX advance normally (wrong path) in the redirect cycle.
// In an ovr_q cycle F fetches from fetch_pc = ovr_tgt_q instead of pc_q,
// IF/ID captures unconditionally (valid = fetch_ok), the hazard unit
// flushes ID and EX kills the instruction it holds. ovr_q stays set until
// a word at the target is actually fetched (fetch_ok), then the PC loads
// the successor of the target. Timeline: branch in EX at t, target fetched
// at t+1, in ID at t+2: the same penalty as a combinational redirect.
//
// Predictor: the imem word is predecoded for BRANCH and JAL. A JAL with an
// aligned target is always predicted taken; a branch with an aligned target
// is predicted from a 512 x 2-bit bimodal BHT indexed by the PC flop
// (pc[10:2], read in parallel with the fetch). A predicted transfer loads
// pc + imm into the PC with no bubble. EX redirects only on a mispredict
// (ID/EX carries the prediction and the alternative target). Misaligned
// targets are never predicted: EX traps them.
//
// The predicted target is a carry-select add: pc[20:2] + imm[20:2] gives a
// carry c, and pc[31:21] is taken as-is, +1 or -1 (both precomputed from
// the PC flop) by {imm sign, c}. The same sum fills the L0 target field.
//
// The BHT write port comes from flops (EX registers the training one
// cycle late).
//
// Latency:        F -> IF/ID register: 1 cycle.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              backend_stall,    // ID cannot take IF/ID
  input  logic              redirect,         // EX mispredict / JALR (sets ovr_q)
  input  logic [31:2]       redirect_target,  // captured while !ovr_q
  // BHT training (registered in EX)
  input  logic              bht_we,
  input  logic [8:0]        bht_widx,
  input  logic [1:0]        bht_wdata,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  // Fetch-override flop copies for the back end (EX kill, ID flush).
  output logic              ovr_ex,
  output logic              ovr_id,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  // The PC is always word-aligned: reset is 0, pc + 4 keeps alignment,
  // and a redirect / prediction only fires for an aligned target (a
  // misaligned one is trapped in EX and never redirects or predicted).
  // So only pc[31:2] is a register, pc[1:0] is the constant 0, and EX can
  // read a branch / JAL target's alignment straight off imm[1:0].
  logic [31:2] pc_q;
  logic [31:0] pc;

  // ── Fetch override ──────────────────────────────────────────────────────
  // ovr_q and its copies all load the same D (set by an EX redirect, held
  // until the target word is fetched); the copies split the select fanout
  // (fetch_pc mux, L0 hit/fill gating, EX kill, ID flush). The L0 is not
  // looked up in an override cycle (it stays indexed by the pc_q copies),
  // so the target must come from the imem bus: fetch_ok = imem_ready there
  // and the hold term has no L0 cone. ovr_tgt_q tracks the EX redirect
  // target every cycle ovr_q is clear, so its enable has no redirect term.
  logic        fetch_ok;
  logic        ovr_d;
  logic        ovr_q;
  (* syn_preserve = 1 *) logic ovr_pc_q;
  (* syn_preserve = 1 *) logic ovr_l0_q;
  (* syn_preserve = 1 *) logic ovr_ex_q;
  (* syn_preserve = 1 *) logic ovr_id_q;
  logic [31:2] ovr_tgt_q;

  assign ovr_d = redirect || (ovr_q && !imem_ready);

  always_ff @(posedge clock) begin
    if (reset) begin
      ovr_q    <= 1'b0;
      ovr_pc_q <= 1'b0;
      ovr_l0_q <= 1'b0;
      ovr_ex_q <= 1'b0;
      ovr_id_q <= 1'b0;
    end else begin
      ovr_q    <= ovr_d;
      ovr_pc_q <= ovr_d;
      ovr_l0_q <= ovr_d;
      ovr_ex_q <= ovr_d;
      ovr_id_q <= ovr_d;
    end
  end

  always_ff @(posedge clock) begin
    if (!ovr_q) ovr_tgt_q <= redirect_target;
  end

  assign ovr_ex = ovr_ex_q;
  assign ovr_id = ovr_id_q;

  logic [31:2] fetch_pc;
  assign fetch_pc = ovr_pc_q ? ovr_tgt_q : pc_q;
  assign pc       = {fetch_pc, 2'b00};

  // ── Bimodal BHT ─────────────────────────────────────────────────────────
  // 512 x 2-bit saturating counters in distributed RAM, initialised to
  // weakly-not-taken. Contents only affect performance, never correctness.
  (* syn_ramstyle = "distributed_ram" *) logic [1:0] bht [0:511];

  initial begin
    for (int i = 0; i < 512; i++) bht[i] = 2'b01;
  end

  always_ff @(posedge clock) begin
    if (bht_we) bht[bht_widx] <= bht_wdata;
  end

  logic [1:0] bht_ctr;
  assign bht_ctr = bht[fetch_pc[10:2]];

  // ── imem-side predecode + predicted target ──────────────────────────────
  logic        is_br;
  logic        is_jal;
  logic        imm1;
  logic        jal_ok;
  logic        br_ok;
  logic        pt_imem;
  logic [20:2] imm_lo;
  logic [19:0] lo_sum;      // [19] = carry out of bit 20
  logic [31:21] pc_hi_p1;
  logic [31:21] pc_hi_m1;
  logic [31:21] tgt_hi;
  logic [31:2] tgt_imem;
  logic [31:2] pc_inc;

  always_comb begin
    // Must match decoder.sv exactly: BRANCH with funct3 not 2/3, JAL.
    is_br  = (imem_data[6:0] == 7'b1100011) && (imem_data[14:13] != 2'b01);
    is_jal = (imem_data[6:0] == 7'b1101111);
    // Target bit 1 (the PC is word-aligned): B imm[1] = instr[8],
    // J imm[1] = instr[21]. instr[3] tells JAL (1) from BRANCH (0).
    imm1    = imem_data[3] ? imem_data[21] : imem_data[8];
    jal_ok  = is_jal && !imm1;
    br_ok   = is_br  && !imm1;
    pt_imem = jal_ok || (br_ok && bht_ctr[1]);

    // imm[20:2] of the B / J immediate.
    if (imem_data[3])
      imm_lo = {imem_data[31], imem_data[19:12], imem_data[20],
                imem_data[30:22]};
    else
      imm_lo = {{8{imem_data[31]}}, imem_data[31], imem_data[7],
                imem_data[30:25], imem_data[11:9]};

    lo_sum   = {1'b0, fetch_pc[20:2]} + {1'b0, imm_lo};
    pc_hi_p1 = fetch_pc[31:21] + 11'd1;
    pc_hi_m1 = fetch_pc[31:21] - 11'd1;
    // hi = pc_hi + sext(sign) + carry
    case ({imem_data[31], lo_sum[19]})
      2'b01:   tgt_hi = pc_hi_p1;
      2'b10:   tgt_hi = pc_hi_m1;
      default: tgt_hi = fetch_pc[31:21];
    endcase
    tgt_imem = {tgt_hi, lo_sum[18:0]};
    pc_inc   = fetch_pc + 30'd1;
  end

  // ── Fetch cache (block RAM, read address register = PC copy) ───────────
  logic        l0_hit;
  logic [31:0] l0_instr;
  logic [31:2] l0_tgt;
  logic        l0_jal_ok;
  logic        l0_br_ok;
  logic        pc_en;
  logic [31:2] pc_d;

  // Indexed by pc_q (its read address loads pc_d with pc_en): no lookup
  // and no fill in an override cycle.
  l0_icache u_l0 (
    .clock    (clock),
    .reset    (reset),
    .pc       (pc_q),
    .rd_en    (pc_en),
    .rd_idx   (pc_d[12:2]),
    .we       (imem_ready && !ovr_l0_q),
    .w_instr  (imem_data),
    .w_tgt    (tgt_imem),
    .w_jal_ok (jal_ok),
    .w_br_ok  (br_ok),
    .hit      (l0_hit),
    .instr    (l0_instr),
    .tgt      (l0_tgt),
    .jal_ok   (l0_jal_ok),
    .br_ok    (l0_br_ok)
  );

  // ── Word source select (imem_ready is a flop) ──────────────────────────
  logic [31:0] word;
  logic        pt;
  logic [31:2] ptgt;
  logic        accept;
  logic        valid_q;

  always_comb begin
    word     = imem_ready ? imem_data : l0_instr;
    pt       = imem_ready ? pt_imem
                          : (l0_jal_ok || (l0_br_ok && bht_ctr[1]));
    ptgt     = imem_ready ? tgt_imem  : l0_tgt;
    fetch_ok = imem_ready || (l0_hit && !ovr_l0_q);
    // ID takes the IF/ID entry this cycle, or IF/ID is empty; in an ovr_q
    // cycle IF/ID always captures (ID's wrong-path entry is flushed).
    accept   = !valid_q || !backend_stall || ovr_q;
  end

  // No redirect level on the PC D input: an override cycle fetches from
  // ovr_tgt_q, and the PC loads that fetch's successor like any other.
  always_comb begin
    pc_en = fetch_ok && accept;
    pc_d  = pt ? ptgt : pc_inc;
  end

  always_ff @(posedge clock) begin
    if (reset)      pc_q <= RESET_PC[31:2];
    else if (pc_en) pc_q <= pc_d;
  end

  assign imem_addr = pc;

  // ── IF/ID register ──────────────────────────────────────────────────────
  // Only valid is reset; the payload is datapath. A wrong-path entry
  // captured in the redirect cycle is flushed in ID during the ovr_q cycle.
  if_id_t data_q;

  always_ff @(posedge clock) begin
    if (reset)       valid_q <= 1'b0;
    else if (accept) valid_q <= fetch_ok;
  end

  always_ff @(posedge clock) begin
    if (accept) begin
      data_q.pc         <= pc;
      data_q.instr      <= word;
      data_q.valid      <= 1'b0;   // unused: out.valid comes from valid_q
      data_q.pred_taken <= pt;
      data_q.bht_ctr    <= bht_ctr;
      // Where the instruction goes if the prediction turns out wrong.
      data_q.alt_target <= pt ? {pc_inc, 2'b00} : {ptgt, 2'b00};
    end
  end

  always_comb begin
    out       = data_q;
    out.valid = valid_q;
  end

endmodule
