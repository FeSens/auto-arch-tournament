// rtl/core.sv
//
// Top-level wiring for the 5-stage in-order RV32IM core.
//
//  IF -> ID -> EX -> MEM -> WB
//   |    |     ^
//   |    +-----+    forward_unit drives EX-stage rs1/rs2 muxes
//   |               from EX/MEM and MEM/WB
//   +- stall <- hazard_unit (load/multiply-use)
//
// IO port names use the `io_*` Chisel-emit prefix so the existing
// formal/wrapper_si.sv and test/cosim/main.cpp bindings carry through
// byte-for-byte. RVFI port set is the single-channel set described in
// CLAUDE.md invariant 1 under `nret: 1` (declared in core.yaml). The
// orchestrator routes formal to wrapper_si.sv + checks_si.cfg and FPGA
// synth to fpga/core_bench_si.sv for this core. There is no channel 1.
//
// Latency:        full pipeline; instruction n retires at MEM/WB on
//                 cycle n+4 (no hazards) or later (load-use stall,
//                 redirect).
// RVFI fields:    all of them — driven from the MEM/WB register and
//                 its selected writeback data.
module core (
  input  logic        clock,
  input  logic        reset,
  // imem
  output logic [31:0] io_imemAddr,
  input  logic [31:0] io_imemData,
  // imem bus backpressure. On a wait, IF can supply the tagged instruction.
  // Used by test/cosim/vex_main.cpp's --istall mode to match VexRiscv's
  // random ~22% backpressure model so CoreMark/MHz can be compared
  // apples-to-apples with their published "full no cache" number.
  input  logic        io_imemReady,
  // dmem
  output logic [31:0] io_dmemAddr,
  input  logic [31:0] io_dmemRData,
  output logic [31:0] io_dmemWData,
  output logic [3:0]  io_dmemWEn,
  output logic        io_dmemREn,
  // An external transaction holds MEM until acceptance. A verified
  // resident word can complete independently of bus backpressure.
  input  logic        io_dmemReady,
  // RVFI — single-channel retirement port set (NRET=1 contract,
  // declared via `nret: 1` in core.yaml). Channel 0 is the sole
  // retirement channel. See CLAUDE.md invariant 1 for the full contract.
  output logic        io_rvfi_valid_0,
  output logic [63:0] io_rvfi_order_0,
  output logic [31:0] io_rvfi_insn_0,
  output logic        io_rvfi_trap_0,
  output logic        io_rvfi_halt_0,
  output logic        io_rvfi_intr_0,
  output logic [1:0]  io_rvfi_mode_0,
  output logic [1:0]  io_rvfi_ixl_0,
  output logic [4:0]  io_rvfi_rs1_addr_0,
  output logic [31:0] io_rvfi_rs1_rdata_0,
  output logic [4:0]  io_rvfi_rs2_addr_0,
  output logic [31:0] io_rvfi_rs2_rdata_0,
  output logic [4:0]  io_rvfi_rd_addr_0,
  output logic [31:0] io_rvfi_rd_wdata_0,
  output logic [31:0] io_rvfi_pc_rdata_0,
  output logic [31:0] io_rvfi_pc_wdata_0,
  output logic [31:0] io_rvfi_mem_addr_0,
  output logic [3:0]  io_rvfi_mem_rmask_0,
  output logic [3:0]  io_rvfi_mem_wmask_0,
  output logic [31:0] io_rvfi_mem_rdata_0,
  output logic [31:0] io_rvfi_mem_wdata_0
);

  // ── Inter-stage wires ──────────────────────────────────────────────────
  if_id_t  if_id_w;
  id_ex_t  id_ex_w;
  ex_mem_t ex_mem_w;
  mem_wb_t mem_wb_w;

  // hazard / forward
  logic       stall_if, stall_id, bubble_id;
  logic       stall_ex_mem, hold_mem_wb;
  logic       div_wait;
  logic [2:0] fwd_rs1_sel, fwd_rs2_sel;
  logic ex_writes, mem_writes;
  logic depends_on_rd;
  logic defer_add, defer_branch, aligned_lw, word_handoff;
  logic late_taken, late_miss, annul;
  logic [31:2] late_next_pc;
  logic serialize;
  logic needs_replay, replay_q, replay, capture_replay;
  logic [31:0] ex_rs1, ex_rs2;
  logic replay_rs1_wb, replay_rs2_wb;

  logic [9:0]  read_index;
  logic [31:0] buffered_word;
  logic        predict_local;
  logic [7:0]  resident_page;
  logic        lookup_page_match;

  // Resolved control flow and prediction recovery.
  logic        recover_target, recover_fallthrough;
  logic [31:2] target;
  logic        fence_i;
  assign fence_i = !annul && !replay && id_ex_w.valid && id_ex_w.instr[6:0] == 7'b0001111
                                 && id_ex_w.instr[14:12] == 3'b001;

  // At this edge the branch retires into WB. A miss invalidates the
  // two speculative slots now entering MEM and EX, including bypass tags.
  always_ff @(posedge clock)
    if (reset) annul <= 1'b0;
    else       annul <= late_miss;

  // regfile interface (driven by ID + WB stages)
  logic [4:0]  rs1_addr_w;
  logic [4:0]  rs2_addr_w;
  logic [31:0] rs1_data_w;
  logic [31:0] rs2_data_w;
  logic        wb_w_en;
  logic [4:0]  wb_w_addr;
  logic [31:0] wb_w_data;

  // This single registered select includes the producer's alignment and
  // destination match. It freezes with the ordinary forwarding selectors.
  always_ff @(posedge clock)
    if (capture_replay) word_handoff <= 1'b0;
    else if (!stall_id)
      word_handoff <= aligned_lw && id_ex_w.rd != 0 && id_ex_w.rd == rs1_addr_w;

  // Register the interlock alongside the fetched instruction. On the
  // bubble edge EX captures the available sources and moves each missing
  // source to its WB bypass. The fetch RAM does not wait for a tag match
  // to select its address on the original issue edge.
  assign replay = replay_q && !annul;
  assign capture_replay = replay && !stall_ex_mem;
  always_ff @(posedge clock) begin
    if (reset || capture_replay) replay_q <= 1'b0;
    else if (!stall_id) replay_q <= needs_replay && if_id_w.valid && !bubble_id;
  end

  // ── IF ────────────────────────────────────────────────────────────────
  if_stage u_if (
    .clock           (clock),
    .reset           (reset),
    .stall           (stall_if),
    .recover_target  (recover_target),
    .recover_fallthrough (recover_fallthrough),
    .late_miss       (late_miss),
    .late_next_pc    (late_next_pc),
    .taken           (ex_mem_w.deferred_branch ? late_taken : ex_mem_w.early_taken),
    .target          (target),
    .train           (ex_mem_w.valid && !annul && ex_mem_w.pc[31:20] == 0),
    .train_target    (ex_mem_w.branch_target),
    .conditional     (ex_mem_w.ctrl.is_branch),
    .eligible_jump   (ex_mem_w.eligible_jump),
    .counter_hit     (ex_mem_w.prediction_matches),
    .old_counter     (ex_mem_w.old_counter),
    .fence_i         (fence_i),
    .issue_pc        (id_ex_w.pc[31:2]),
    .train_pc        (ex_mem_w.pc[19:2]),
    .issue_instr     (ex_mem_w.instr),
    .producer_rd     (id_ex_w.rd),
    .producer_lw     (id_ex_w.ctrl.mem_read && id_ex_w.ctrl.mem_width == 2),
    .depends_on_rd   (depends_on_rd),
    .serializing     (serialize),
    .imem_addr       (io_imemAddr),
    .imem_data       (io_imemData),
    .imem_ready      (io_imemReady),
    .out             (if_id_w)
  );

  // ── ID + regfile ──────────────────────────────────────────────────────
  id_stage u_id (
    .clock    (clock),
    .reset    (reset),
    .stall    (stall_id),
    .bubble   (bubble_id),
    .capture_replay (capture_replay),
    .ex_rs1   (ex_rs1),
    .ex_rs2   (ex_rs2),
    .in       (if_id_w),
    .rs1_addr (rs1_addr_w),
    .rs2_addr (rs2_addr_w),
    .rs1_data (rs1_data_w),
    .rs2_data (rs2_data_w),
    .out      (id_ex_w)
  );

  reg_file u_rf (
    .clock    (clock),
    .reset    (reset),
    .rs1_addr (rs1_addr_w),
    .rs2_addr (rs2_addr_w),
    .rs1_data (rs1_data_w),
    .rs2_data (rs2_data_w),
    .w_en     (wb_w_en),
    .w_addr   (wb_w_addr),
    .w_data   (wb_w_data)
  );

  // ── EX ────────────────────────────────────────────────────────────────
  ex_stage u_ex (
    .clock           (clock),
    .reset           (reset),
    .stall           (stall_ex_mem),
    .annul           (annul || replay),
    .word_handoff    (word_handoff),
    .predict_local   (predict_local),
    .buffered_word   (buffered_word),
    .bus_word        (io_dmemRData),
    .resident_page   (resident_page),
    .read_index      (read_index),
    .lookup_page_match (lookup_page_match),
    .in              (id_ex_w),
    .fwd_rs1_sel     (fwd_rs1_sel),
    .fwd_rs2_sel     (fwd_rs2_sel),
    .fwd_ex_mem      (ex_mem_w.alu_result),  // EX/MEM-registered ALU result
    .fwd_mem_wb      (wb_w_data),            // Result selected before MEM/WB
    .wb_alu_word     (mem_wb_w.alu_result[31:2]),
    .wb_mem_word     (mem_wb_w.read_data[31:2]),
    .wb_mem_to_reg   (mem_wb_w.ctrl.mem_to_reg),
    .out             (ex_mem_w),
    .producer_writes (ex_writes),
    .aligned_lw      (aligned_lw),
    .defer_add       (defer_add),
    .defer_branch    (defer_branch),
    .rs1             (ex_rs1),
    .rs2             (ex_rs2),
    .late_rs1        (replay_rs1_wb),
    .late_rs2        (replay_rs2_wb),
    .div_wait        (div_wait),
    .target_word     (target),
    .recover_target  (recover_target),
    .recover_fallthrough (recover_fallthrough)
  );

  // ── MEM ───────────────────────────────────────────────────────────────
  logic read_access;
  logic [3:0] store_mask;
  logic [31:0] completing_word;
  mem_stage u_mem (
    .clock      (clock),
    .reset      (reset),
    .hold_wb    (hold_mem_wb),
    .annul      (annul),
    .late_taken (late_taken),
    .late_miss  (late_miss),
    .late_next_pc (late_next_pc),
    .in         (ex_mem_w),
    .dmem_addr  (io_dmemAddr),
    .dmem_wdata (io_dmemWData),
    .dmem_rdata (completing_word),
    .dmem_wen   (store_mask),
    .dmem_ren   (read_access),
    .producer_writes (mem_writes),
    .out        (mem_wb_w)
  );

  // Observe each completed ordinary-RAM reference once, off the address
  // forwarding path. Nine consecutive references to a challenger select
  // its page. The data RAM is usable only after all presence bits clear.
  logic reference_valid, page_ready, clearing;
  logic [7:0] reference_page, challenger;
  logic [3:0] references;
  logic [9:0] clear_index;
  always_ff @(posedge clock) begin
    reference_valid <= !reset && !stall_ex_mem && io_dmemAddr[31:20] == 0 &&
                       (read_access || |store_mask);
    reference_page <= io_dmemAddr[19:12];
    if (reset) begin
      references <= 0;
      clearing <= 1'b0;
      page_ready <= 1'b0;
    end else if (clearing) begin
      clear_index <= clear_index + 1'b1;
      if (&clear_index) begin
        clearing <= 1'b0;
        page_ready <= 1'b1;
      end
    end else if (reference_valid) begin
      challenger <= reference_page;
      if (page_ready && reference_page == resident_page) begin
        references <= 0;
      end else if (references == 0 || reference_page != challenger) begin
        references <= 1;
      end else if (references == 8) begin
        resident_page <= reference_page;
        references <= 0;
        clear_index <= 0;
        clearing <= 1'b1;
        page_ready <= 1'b0;
      end else begin
        references <= references + 1'b1;
      end
    end
  end

  logic present_q, row_correct_q, can_predict_q;
  logic collision_q;
  wire page_match = io_dmemAddr[31:12] == {12'b0, resident_page};
  wire verified = page_ready && lookup_page_match && row_correct_q && !collision_q;
  assign predict_local = present_q && can_predict_q;
  assign completing_word = predict_local ? buffered_word : io_dmemRData;
  assign io_dmemREn = read_access && !predict_local && !reset;
  assign io_dmemWEn = reset ? 4'b0 : store_mask;

  // A bad source prediction blocks both instructions even on a ready bus.
  // Once held, the access uses the bus until acceptance, including across
  // page transitions. read_access already includes alignment and annul.
  wire bus_wait = !io_dmemReady && (read_access || |store_mask);
  wire mem_wait = predict_local ? (read_access && !verified) : bus_wait;
  // A wait pins the source to the bus on every subsequent cycle. Gating
  // admission at issue also excludes the last row invalidated by a sweep.
  always_ff @(posedge clock)
    can_predict_q <= !mem_wait && page_ready && id_ex_w.ctrl.mem_read &&
                     !annul && !replay && !reset;

  wire update_word = page_ready && page_match && io_dmemReady &&
                     (io_dmemREn || |io_dmemWEn);
  wire [9:0] write_index = io_dmemAddr[11:2];
  wire [31:0] fill_word = read_access ? io_dmemRData : io_dmemWData;
  for (genvar lane = 0; lane < 4; lane++) begin : gen_data
    (* syn_ramstyle = "block_ram" *) logic [7:0] bytes [0:1023];
    always_ff @(posedge clock) begin
      if (update_word && (read_access || io_dmemWEn[lane]))
        bytes[write_index] <= fill_word[lane*8 +: 8];
      if (!stall_ex_mem)
        buffered_word[lane*8 +: 8] <= bytes[read_index];
    end
  end

  (* syn_ramstyle = "block_ram" *) logic present [0:1023];
  wire [9:0] presence_index = clearing ? clear_index : write_index;
  always_ff @(posedge clock) begin
    if (clearing || (update_word && (read_access || &io_dmemWEn)))
      present[presence_index] <= !clearing;
    if (!stall_ex_mem) begin
      present_q <= present[read_index];
      // On an advancing edge the predicted source has been verified.
      // A pointer from the bus made the independent index speculative.
      row_correct_q <= !word_handoff || predict_local;
      // Compare the RAM port addresses on the access edge. row_correct_q
      // independently rejects a speculative read of the wrong row.
      collision_q <= update_word && write_index == read_index;
    end
  end

  // ── WB ────────────────────────────────────────────────────────────────
  wb_stage u_wb (
    .in     (mem_wb_w),
    .w_en   (wb_w_en),
    .w_addr (wb_w_addr),
    .w_data (wb_w_data)
  );

  // ── Hazard / forwarding ───────────────────────────────────────────────
  hazard_unit u_hazard (
    .id_ex_late_result (!annul && id_ex_w.valid && (id_ex_w.ctrl.mem_to_reg || defer_add)),
    .id_ex_rd       (id_ex_w.rd),
    .depends_on_rd  (depends_on_rd),
    .redirect       (recover_target || recover_fallthrough),
    .fence_i        (fence_i),
    .serialize      (defer_branch && !annul && serialize),
    .replay         (replay),
    .needs_replay   (needs_replay),
    .div_wait       (div_wait),
    .fetch_valid    (if_id_w.valid),
    .dmem_stall     (mem_wait),
    .stall_if       (stall_if),
    .stall_id       (stall_id),
    .bubble_id      (bubble_id),
    .stall_ex_mem   (stall_ex_mem),
    .hold_mem_wb    (hold_mem_wb)
  );

  forward_unit u_fwd (
    .clock       (clock),
    .stall_id    (stall_id),
    .capture_replay (capture_replay),
    .late_rs1    (replay_rs1_wb),
    .late_rs2    (replay_rs2_wb),
    .if_id_rs1   (rs1_addr_w),
    .if_id_rs2   (rs2_addr_w),
    .id_ex_rd    (id_ex_w.rd),
    .ex_mem_rd   (ex_mem_w.rd),
    .ex_writes   (ex_writes),
    .mem_writes  (mem_writes),
    .fwd_rs1     (fwd_rs1_sel),
    .fwd_rs2     (fwd_rs2_sel)
  );

  // ── RVFI ──────────────────────────────────────────────────────────────
  // The MEM/WB register is the retirement boundary. rvfi_order increments
  // every cycle rvfi_valid is high; CLAUDE.md invariant 4 (riscv-formal
  // unique-check) requires strict +1.
  logic [63:0] rvfi_order_q;
  logic        rd_wen;

  always_ff @(posedge clock) begin
    if (reset)                rvfi_order_q <= 64'b0;
    else if (mem_wb_w.valid)  rvfi_order_q <= rvfi_order_q + 64'b1;
  end

  always_comb begin
    rd_wen = mem_wb_w.ctrl.reg_write && (mem_wb_w.rd != 5'b0);

    // Channel 0: the only retirement channel for the single-issue baseline.
    io_rvfi_valid_0     = mem_wb_w.valid;
    io_rvfi_order_0     = rvfi_order_q;
    io_rvfi_insn_0      = mem_wb_w.instr;
    io_rvfi_trap_0      = mem_wb_w.ctrl.is_illegal;
    io_rvfi_halt_0      = 1'b0;
    io_rvfi_intr_0      = 1'b0;
    io_rvfi_mode_0      = 2'd3;     // M-mode only
    io_rvfi_ixl_0       = 2'd1;     // 32-bit ISA
    io_rvfi_rs1_addr_0  = mem_wb_w.rs1_addr;
    io_rvfi_rs1_rdata_0 = mem_wb_w.rs1_val;
    io_rvfi_rs2_addr_0  = mem_wb_w.rs2_addr;
    io_rvfi_rs2_rdata_0 = mem_wb_w.rs2_val;
    io_rvfi_rd_addr_0   = rd_wen ? mem_wb_w.rd : 5'b0;
    io_rvfi_rd_wdata_0  = rd_wen ? wb_w_data   : 32'b0;
    io_rvfi_pc_rdata_0  = mem_wb_w.pc;
    io_rvfi_pc_wdata_0  = mem_wb_w.pc_next;
    io_rvfi_mem_addr_0  = mem_wb_w.mem_addr;
    io_rvfi_mem_rmask_0 = mem_wb_w.mem_rmask;
    io_rvfi_mem_wmask_0 = mem_wb_w.mem_wmask;
    io_rvfi_mem_rdata_0 = mem_wb_w.mem_rdata;
    io_rvfi_mem_wdata_0 = mem_wb_w.mem_wdata;
  end

endmodule
