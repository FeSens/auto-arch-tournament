// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// On flush or redirect, the instruction emitted to ID is forced to NOP
// (`0x00000013` = ADDI x0,x0,0). This prevents the hazard unit from
// observing a real rs1/rs2 from a wrong-path instruction and inserting
// a spurious load-use stall the cycle after a taken branch.
//
// Stall-only replay store. A 512-entry direct-mapped table (index
// pc[10:2], tag pc[31:11], 32-bit word) is filled with the fetched word
// on every imem_ready cycle. It is consumed only on cycles where the
// external imem does NOT accept the fetch: if the table held the current
// PC, IF supplies the replayed word and the fetch proceeds as if the bus
// had delivered it. Instruction memory is read-only in this contract
// (stores never reach imem, FENCE.I is a NOP), so an entry can never be
// stale and needs no invalidation beyond reset.
//
// The table is never read on the fetch-ready path. It is read
// synchronously, addressed by pc_d (the PC flop's D input, i.e. next
// cycle's PC), into the candidate registers cand_hit_q / cand_instr_q,
// which by construction describe the current PC. The only same-cycle
// additions are fetch_ready = imem_ready | cand_hit_q and the
// imem_ready-selected word mux. With imem_ready tied to 1 (FPGA bench,
// formal wrapper) the whole store constant-folds away.
//
// When pc_d == pc (PC held by a stall, or redirected onto itself) on a
// cycle where IF already has the word (fetch_ready: live or replayed),
// the candidate keeps that word instead of re-reading the table. This
// covers the same-edge fill of a held PC that the synchronous read would
// miss, so a PC fetched once is always a replay hit (barring an alias
// eviction at the same index).
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect); insn is the live or replayed word.
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (any stall reason)
  input  logic              flush,            // emit NOP into ID this cycle
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,       // external imem delivered imem_data
  output logic              fetch_ready,      // IF has the word at pc (live or replay)
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC   = 32'h0000_0000;
  localparam int          RP_IDX_W   = 9;                   // 512 entries
  localparam int          RP_ENTRIES = 1 << RP_IDX_W;
  localparam int          RP_TAG_LSB = RP_IDX_W + 2;        // tag = pc[31:11]
  localparam int          RP_TAG_W   = 32 - RP_TAG_LSB;

  logic [31:0] pc;
  logic [31:0] pc_d;

  // Redirect must override stall: a BRANCH/JAL/JALR in EX may fire
  // redirect on the same cycle as imem_stall or dmem_stall — without
  // this priority the redirect target would be silently dropped, the
  // PC would hold its old (wrong-path) value, and execution would
  // resume on the wrong path once the bus unstalls. Verified by the
  // VexRiscv-binary CoreMark sweep with --istall enabled.
  //
  // pc_d is also the replay-store lookahead address, so the candidate
  // registers always describe the PC this flop holds next cycle.
  always_comb begin
    pc_d = redirect ? redirect_target : (!stall ? pc + 32'd4 : pc);
  end

  always_ff @(posedge clock) begin
    if (reset) pc <= RESET_PC;
    else       pc <= pc_d;
  end

  assign imem_addr = pc;

  // ── Replay store ──────────────────────────────────────────────────────
  // valid[] is reset; tag/data are resetless and never read without it.
  logic [RP_ENTRIES-1:0] rp_valid;
  logic [RP_TAG_W-1:0]   rp_tag  [0:RP_ENTRIES-1];
  logic [31:0]           rp_data [0:RP_ENTRIES-1];

  logic [RP_IDX_W-1:0]   fill_idx;
  logic [RP_IDX_W-1:0]   look_idx;
  logic                  look_keep;
  logic                  look_hit;
  logic                  cand_hit_q;
  logic [31:0]           cand_instr_q;
  logic [31:0]           instr_word;

  always_comb begin
    fill_idx    = pc[RP_TAG_LSB-1:2];
    look_idx    = pc_d[RP_TAG_LSB-1:2];

    fetch_ready = imem_ready || cand_hit_q;
    instr_word  = imem_ready ? imem_data : cand_instr_q;

    // Next PC is this PC and IF already has its word: carry it into the
    // candidate (the table read would miss a same-edge fill).
    look_keep   = fetch_ready && (pc_d == pc);
    look_hit    = rp_valid[look_idx]
               && (rp_tag[look_idx] == pc_d[31:RP_TAG_LSB]);
  end

  // A same-edge fill to look_idx for a different PC is benign: the read
  // returns the pre-fill entry and the tag check decides.
  always_ff @(posedge clock) begin
    if (imem_ready) begin
      rp_tag[fill_idx]  <= pc[31:RP_TAG_LSB];
      rp_data[fill_idx] <= imem_data;
    end
    cand_instr_q <= look_keep ? instr_word : rp_data[look_idx];
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      rp_valid   <= '0;
      cand_hit_q <= 1'b0;
    end else begin
      if (imem_ready) rp_valid[fill_idx] <= 1'b1;
      cand_hit_q <= look_keep || look_hit;
    end
  end

  always_comb begin
    out.pc    = pc;
    out.instr = (flush || redirect) ? 32'h0000_0013 : instr_word;
    out.valid = !(flush || redirect);
  end

endmodule
