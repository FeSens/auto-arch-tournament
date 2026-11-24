// rtl/core.sv
//
// Top-level wiring for the 5-stage in-order RV32IM core.
//
//  IF -> ID -> EX -> MEM -> WB
//   |    |     ^
//   |    +-----+    forward_unit drives EX-stage rs1/rs2 muxes
//   |               from EX/MEM and MEM/WB
//   +- stall <- hazard_unit (load replay or M-extension result dependency)
//
// IO port names use the `io_*` Chisel-emit prefix so the existing
// formal/wrapper_si.sv and test/cosim/main.cpp bindings carry through
// byte-for-byte. RVFI port set is the single-channel set described in
// CLAUDE.md invariant 1 under `nret: 1` (declared in core.yaml). The
// orchestrator routes formal to wrapper_si.sv + checks_si.cfg and FPGA
// synth to fpga/core_bench_si.sv for this core. There is no channel 1.
//
// Latency:        full pipeline; instruction n retires at MEM/WB on
//                 cycle n+4 (no hazards) or later (load replay, M-extension stall,
//                 redirect).
// RVFI fields:    all of them — driven from the MEM/WB register and
//                 the WB-stage write-data mux.
module core (
  input  logic        clock,
  input  logic        reset,
  // imem
  output logic [31:0] io_imemAddr,
  input  logic [31:0] io_imemData,
  // imem bus backpressure. Drive 1 for zero-wait single-cycle BRAM (the
  // V0 default). When low, fetch can issue a verified successor word.
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
  // An external read or write holds MEM while ready is low. A verified
  // internal word can complete its load on any cycle.
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
  logic       stall_if, stall_id, flush_id;
  logic       stall_ex_mem, hold_mem_wb;
  logic       div_wait;
  bypass_t    fwd_rs1_sel, fwd_rs2_sel;
  bypass_t    alu_b_sel, unused_rs1_alu_sel;
  logic       dec_alu_src;
  logic [7:0] lookup_index;
  logic [31:0] predicted_value;
  logic       rs1_trace_load, rs2_trace_load;
  logic       decode_uses_rs1, decode_uses_rs2;
  logic       load_hit, replay;
  logic       ex_will_write, mem_will_write;

  // EX redirect
  logic        redirect;
  logic [31:0] redirect_target;
  logic        fence_i;
  logic        train_en;
  logic [6:0]  train_index;
  logic [1:0]  train_counter;

  // regfile interface (driven by ID + WB stages)
  logic [4:0]  rs1_addr_w;
  logic [4:0]  rs2_addr_w;
  logic [31:0] rs1_data_w;
  logic [31:0] rs2_data_w;
  logic        wb_w_en;
  logic [4:0]  wb_w_addr;
  logic [31:0] wb_w_data;

  // ── IF ────────────────────────────────────────────────────────────────
  if_stage u_if (
    .clock           (clock),
    .reset           (reset),
    .stall           (stall_if),
    .imem_ready      (io_imemReady),
    .redirect        (redirect),
    .redirect_target (redirect_target),
    .fence_i         (fence_i),
    .train_en        (train_en),
    .train_index     (train_index),
    .train_counter   (train_counter),
    .imem_addr       (io_imemAddr),
    .imem_data       (io_imemData),
    .out             (if_id_w)
  );

  // ── ID + regfile ──────────────────────────────────────────────────────
  id_stage u_id (
    .clock    (clock),
    .reset    (reset),
    .stall    (stall_id),
    .flush    (flush_id),
    .in       (if_id_w),
    .dec_alu_src (dec_alu_src),
    .rs1_addr (rs1_addr_w),
    .rs2_addr (rs2_addr_w),
    .rs1_data (rs1_data_w),
    .rs2_data (rs2_data_w),
    .wb_en    (wb_w_en),
    .wb_rd    (wb_w_addr),
    .wb_value (wb_w_data),
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
    .replay          (replay),
    .in              (id_ex_w),
    .fwd_rs1_sel     (fwd_rs1_sel),
    .fwd_rs2_sel     (fwd_rs2_sel),
    .alu_b_sel       (alu_b_sel),
    .fwd_ex_mem      (ex_mem_w.alu_result),  // EX/MEM-registered ALU result
    .fwd_mem_wb      (wb_w_data),            // WB-stage's write-mux output
    .predicted_value (predicted_value),
    .rs1_trace_load  (rs1_trace_load),
    .rs2_trace_load  (rs2_trace_load),
    .lookup_index    (lookup_index),
    .out             (ex_mem_w),
    .div_wait        (div_wait),
    .will_write      (ex_will_write),
    .fence_i         (fence_i),
    .redirect        (redirect),
    .redirect_target (redirect_target),
    .train_en        (train_en),
    .train_index     (train_index),
    .train_counter   (train_counter)
  );

  // ── MEM ───────────────────────────────────────────────────────────────
  mem_stage u_mem (
    .clock          (clock),
    .reset          (reset),
    .hold_wb        (hold_mem_wb),
    .in             (ex_mem_w),
    .lookup_index   (lookup_index),
    .lookup_word    (id_ex_w.ctrl.mem_width[1]),
    .predicted_value (predicted_value),
    .load_hit       (load_hit),
    .will_write     (mem_will_write),
    .dmem_ready     (io_dmemReady),
    .dmem_addr      (io_dmemAddr),
    .dmem_wdata     (io_dmemWData),
    .dmem_rdata     (io_dmemRData),
    .dmem_wen       (io_dmemWEn),
    .dmem_ren       (io_dmemREn),
    .out            (mem_wb_w)
  );

  // ── WB ────────────────────────────────────────────────────────────────
  wb_stage u_wb (
    .in     (mem_wb_w),
    .w_en   (wb_w_en),
    .w_addr (wb_w_addr),
    .w_data (wb_w_data)
  );

  // ── Hazard / forwarding ───────────────────────────────────────────────
  assign replay = id_ex_w.valid && !load_hit && (fwd_rs1_sel.load || fwd_rs2_sel.load);

`ifdef VERILATOR
  // Optional cosim measurement. Count a MEM producer once on release,
  // even if it waited several clocks or both source registers depend on it.
  logic profile_window;
  int unsigned subword_uses, subword_hits;
  always_ff @(posedge clock) begin
    if (reset) begin
      profile_window <= 1'b0;
      subword_uses <= 0;
      subword_hits <= 0;
    end else if ($test$plusargs("load_profile")) begin
      if (io_dmemReady && |io_dmemWEn && io_dmemAddr == 32'h10000100) begin
        profile_window <= 1'b1;
        subword_uses <= 0;
        subword_hits <= 0;
      end
      if (profile_window && io_dmemReady && |io_dmemWEn && io_dmemAddr == 32'h10000104) begin
        profile_window <= 1'b0;
        $display("Adjacent dependent subword loads: %0d signature hits in %0d uses",
                 subword_hits, subword_uses);
      end
      if (profile_window && id_ex_w.valid && !stall_ex_mem && !ex_mem_w.ctrl.mem_width[1]
          && (fwd_rs1_sel.load || fwd_rs2_sel.load)) begin
        subword_uses <= subword_uses + 1;
        if (load_hit) subword_hits <= subword_hits + 1;
      end
    end
  end
`endif

  hazard_unit u_hazard (
    .id_ex_wb_only  (id_ex_w.valid && id_ex_w.wb_only),
    .id_ex_rd       (id_ex_w.rd),
    .if_id_rs1      (if_id_w.instr[19:15]),
    .if_id_rs2      (if_id_w.instr[24:20]),
    .redirect       (redirect),
    .fetch_available (if_id_w.valid),
    .dmem_ready     (io_dmemReady),
    .bus_request    (io_dmemREn || (|io_dmemWEn)),
    .replay         (replay),
    .div_wait       (div_wait),
    .stall_if       (stall_if),
    .stall_id       (stall_id),
    .flush_id       (flush_id),
    .stall_ex_mem   (stall_ex_mem),
    .hold_mem_wb    (hold_mem_wb)
  );

  // Speculate only where the instruction uses an architectural operand.
  // Raw register fields in immediate encodings still travel with RVFI.
  always_comb begin
    case (if_id_w.instr[6:0])
      7'h33, 7'h23, 7'h63: {decode_uses_rs1, decode_uses_rs2} = 2'b11;
      7'h13, 7'h03, 7'h67: {decode_uses_rs1, decode_uses_rs2} = 2'b10;
      default:             {decode_uses_rs1, decode_uses_rs2} = 2'b00;
    endcase
  end

  forward_unit u_fwd_rs1 (
    .clock       (clock),
    .reset       (reset),
    .hold_id     (stall_id),
    .hold_mem    (stall_ex_mem),
    .decode_rs   (if_id_w.instr[19:15]),
    .decode_uses_rs (decode_uses_rs1),
    .alu_uses_rs (1'b1),
    .id_ex_load  (id_ex_w.ctrl.mem_read),
    .ex_will_write (ex_will_write),
    .id_ex_rd    (id_ex_w.rd),
    .ex_mem_rd   (ex_mem_w.rd),
    .mem_will_write (mem_will_write),
    .sel         (fwd_rs1_sel),
    .alu_sel     (unused_rs1_alu_sel),
    .trace_load  (rs1_trace_load)
  );

  forward_unit u_fwd_rs2 (
    .clock       (clock),
    .reset       (reset),
    .hold_id     (stall_id),
    .hold_mem    (stall_ex_mem),
    .decode_rs   (if_id_w.instr[24:20]),
    .decode_uses_rs (decode_uses_rs2),
    .alu_uses_rs (!(stall_id ? id_ex_w.ctrl.alu_src : dec_alu_src)),
    .id_ex_load  (id_ex_w.ctrl.mem_read),
    .ex_will_write (ex_will_write),
    .id_ex_rd    (id_ex_w.rd),
    .ex_mem_rd   (ex_mem_w.rd),
    .mem_will_write (mem_will_write),
    .sel         (fwd_rs2_sel),
    .alu_sel     (alu_b_sel),
    .trace_load  (rs2_trace_load)
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
