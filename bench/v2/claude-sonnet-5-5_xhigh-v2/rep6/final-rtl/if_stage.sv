// rtl/if_stage.sv
//
// Instruction fetch stage: the fetch PC (fpc), the I-cache, the fetch-time
// predictor and the real F/D flop stage {pc, instr, valid, prediction}.
//
// Fetch cycle (fpc presented on imem_addr and to the cache):
//   hit      = cache tag/valid compare (late, never in the fpc loop)
//   slot_ok  = hit | imem_ready      -> the slot has an instruction
//   slot     = bus word if the bus delivered, else the cache word
//              (`hit` only reaches the 1-bit F/D control flops, never the
//              32-bit instruction capture)
//
// The next-PC loop is tag-free and bus-free:
//   spec_taken / spec_tgt come from the tag-independent hint read + BHT read,
//   next_fpc = kill ? kill_target
//            : fd_redirect ? (fd_replay ? fd_pc : fd_pc + 1)
//            : spec_taken ? spec_tgt : fpc + 1
//   fpc CE   = kill | !hold          (hold = load-use | dmem | MDU stall)
// Everything that depends on `hit` / `imem_ready` ends at a flop D/CE pin and
// is verified one cycle later from registered flags:
//   - replay  (fd_replay): the slot got no instruction (miss and the bus was
//     not ready). F/D holds a bubble; fpc <= fd_pc (re-fetch it) and the
//     slot fetched this cycle is squashed to a bubble.
//   - alias fix (fd_redirect && !fd_replay): a miss whose (tag-independent)
//     hint said "taken": the hint belonged to another pc, so the speculative
//     redirect is bogus. The slot itself is valid (it came from the bus); the
//     younger wrong-path fetch is squashed and fpc <= fd_pc + 1. On a miss the
//     slot carries pred_taken = 0 (no prediction followed).
// fd_redirect / fd_replay are flops, and the redirect target is built from the
// registered fd_pc only, so neither joins the kill / EX cone.
//
// F/D updates whenever ID consumes it (!hold); `kill` (registered EX
// mispredict recovery) overrides everything: F/D <= bubble, fpc <= kill_target.
// A bubble slot is {garbage instruction, valid = 0, no prediction}; the
// instruction flops are data-only (clock enable, no reset / kill / NOP), and
// id_stage gates the decoded control bundle with `valid`, so a bubble cannot
// write, redirect or trap.
//
// Latency:        fpc update and F/D capture are synchronous (1 cycle).
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage resolve).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              hold,             // load-use / dmem / MDU stall
  input  logic              kill,             // EX mispredict recovery
  // kill_target[1:0] is always 0 (recovery targets are word aligned)
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]       kill_target,      // corrected PC (registered)
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic              imem_ready,
  // BHT update from EX
  input  logic              bht_upd_valid,
  input  logic [7:0]        bht_upd_idx,
  input  logic              bht_upd_taken,
  input  logic [1:0]        bht_upd_cnt,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:2] RESET_PC = 30'd0;

  // pc[1:0] is always 0 (misaligned targets trap and are never followed), so
  // the front end only keeps pc[31:2].
  logic [31:2] fpc;
  logic [31:2] fpc_plus1;
  logic [31:2] next_fpc;

  assign fpc_plus1 = fpc + 30'd1;
  assign imem_addr = {fpc, 2'b00};

  // ── F/D register ──────────────────────────────────────────────────────
  logic [31:2] fd_pc;
  logic [31:0] fd_instr;
  logic        fd_valid;
  logic        fd_pred_taken;
  logic [31:2] fd_pred_target;
  logic [1:0]  fd_bht_cnt;
  logic        fd_redirect;   // alias fix or replay pending for the F/D slot
  logic        fd_replay;     // the F/D slot got no instruction

  // ── Cache + predictor ─────────────────────────────────────────────────
  logic        hit;
  logic [31:0] c_data;
  logic        h_always, h_br, h_ret, h_call;
  logic [19:2] h_tgt;
  logic        f_always, f_br, f_ret, f_call;
  logic [19:2] f_tgt;
  logic        spec_taken;
  logic [31:2] spec_tgt;
  logic [1:0]  bht_cnt;
  logic        slot_ok;
  logic        fire;

  assign slot_ok = hit || imem_ready;
  // RAS update strobe: the fetch is not held, not wrong-path and not squashed
  // by a replay / alias fix of the older slot. Early flop/input terms only (no
  // `hit`); a replayed fetch (miss + bus stall) may pollute the RAS, which is
  // performance-only.
  assign fire    = !hold && !kill && !fd_redirect;

  icache u_ic (
    .clock      (clock),
    .reset      (reset),
    .pc         (fpc),
    .hit        (hit),
    .data       (c_data),
    .h_always   (h_always),
    .h_br       (h_br),
    .h_ret      (h_ret),
    .h_call     (h_call),
    .h_tgt      (h_tgt),
    .fill_valid (imem_ready),
    .fill_data  (imem_data),
    .f_always   (f_always),
    .f_br       (f_br),
    .f_ret      (f_ret),
    .f_call     (f_call),
    .f_tgt      (f_tgt)
  );

  branch_predictor u_bp (
    .clock       (clock),
    .reset       (reset),
    .pc          (fpc),
    .instr       (imem_data),
    .pc_plus4    (fpc_plus1),
    .fire        (fire),
    .bus_ok      (imem_ready),
    .h_always    (h_always),
    .h_br        (h_br),
    .h_ret       (h_ret),
    .h_call      (h_call),
    .h_tgt       (h_tgt),
    .spec_taken  (spec_taken),
    .spec_tgt    (spec_tgt),
    .bht_cnt     (bht_cnt),
    .f_always    (f_always),
    .f_br        (f_br),
    .f_ret       (f_ret),
    .f_call      (f_call),
    .f_tgt       (f_tgt),
    .upd_valid   (bht_upd_valid),
    .upd_idx     (bht_upd_idx),
    .upd_taken   (bht_upd_taken),
    .upd_cnt     (bht_upd_cnt)
  );

  // ── Next fpc ──────────────────────────────────────────────────────────
  // The early (flop-sourced) alternatives are merged first; the late
  // speculative select only enters at the last mux.
  logic [31:2] early_pc;
  logic        sel_spec;

  always_comb begin
    if (kill)             early_pc = kill_target[31:2];
    else if (fd_redirect) early_pc = fd_replay ? fd_pc : (fd_pc + 30'd1);
    else                  early_pc = fpc_plus1;

    sel_spec = spec_taken && !kill && !fd_redirect;
    next_fpc = sel_spec ? spec_tgt : early_pc;
  end

  // kill must override hold: the recovery target is registered and the
  // wrong-path front end has to be abandoned even if a load-use hazard is
  // holding the PC.
  always_ff @(posedge clock) begin
    if (reset)                fpc <= RESET_PC;
    else if (kill || !hold)   fpc <= next_fpc;
  end

  // ── F/D control (reset / bubble) ──────────────────────────────────────
  // Only these 1-bit flops see reset / kill / squash and the cache `hit`.
  always_ff @(posedge clock) begin
    if (reset || kill) begin
      fd_valid      <= 1'b0;
      fd_pred_taken <= 1'b0;
      fd_redirect   <= 1'b0;
      fd_replay     <= 1'b0;
    end else if (!hold) begin
      if (fd_redirect) begin
        // the slot fetched this cycle is wrong-path / a repeat: squash it
        fd_valid      <= 1'b0;
        fd_pred_taken <= 1'b0;
        fd_redirect   <= 1'b0;
        fd_replay     <= 1'b0;
      end else begin
        fd_valid      <= slot_ok;
        fd_pred_taken <= hit && spec_taken;
        fd_redirect   <= !hit && (spec_taken || !imem_ready);
        fd_replay     <= !slot_ok;
      end
    end
  end

  // ── F/D data (only consumed when fd_valid / a flag is set) ────────────
  // No reset, no bubble clear, no `hit`: the bus word is authoritative when
  // the bus delivered (equal to the cached copy on a hit); otherwise the slot
  // is either a hit (c_data is the instruction) or a miss/replay slot
  // (fd_valid = 0, the word is garbage and id_stage zeroes its ctrl).
  always_ff @(posedge clock) begin
    if (!hold) begin
      fd_instr       <= imem_ready ? imem_data : c_data;
      fd_pc          <= fpc;
      fd_pred_target <= spec_tgt;
      fd_bht_cnt     <= bht_cnt;
    end
  end

  always_comb begin
    out.pc          = {fd_pc, 2'b00};
    out.instr       = fd_instr;
    out.valid       = fd_valid;
    out.pred_taken  = fd_pred_taken;
    out.pred_target = fd_pred_target;
    out.bht_cnt     = fd_bht_cnt;
  end

endmodule
