// rtl/core.sv
//
// Top-level wiring for the 5-stage in-order RV32IM core.
//
//  IF -> ID -> EX -> MEM -> WB
//  ID captures write-first RF operands on MEM completion. EX can override
//  either operand with the immediately preceding instruction's result.
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
// RVFI fields:    driven from the MEM/WB register.
module core (
  input  logic        clock,
  input  logic        reset,
  // imem
  output logic [31:0] io_imemAddr,
  input  logic [31:0] io_imemData,
  // A ready bus supplies the fetch word. A stalled bus can be bypassed
  // when the two-issue lookahead word matches the fetch PC.
  input  logic        io_imemReady,
  // dmem
  output logic [31:0] io_dmemAddr,
  input  logic [31:0] io_dmemRData,
  output logic [31:0] io_dmemWData,
  output logic [3:0]  io_dmemWEn,
  output logic        io_dmemREn,
  // A pending dmem request holds the pipeline until the bus is ready.
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
  logic       stall_ex_mem, hold_mem_wb, div_wait;

  // EX redirect
  logic        redirect;
  logic [31:2] redirect_target;
  logic        train;
  logic [1:0]  train_counter;

  // Register file and decode bypass
  logic [4:0]  rs1_addr_w;
  logic [4:0]  rs2_addr_w;
  logic [31:0] fetch_rs1_data, fetch_rs2_data;
  logic        mem_bypass_en;
  logic [31:0] mem_bypass_data;
  logic [31:0] id_rs1_data, id_rs2_data;
  logic        rs1_match_ex, rs2_match_ex, rs1_ex_ready, rs2_ex_ready;

  // ── IF ────────────────────────────────────────────────────────────────
  if_stage u_if (
    .clock           (clock),
    .reset           (reset),
    .stall           (stall_if),
    .issue           (!stall_if && !redirect),
    .stall_id        (stall_id),
    .redirect        (redirect),
    .redirect_target (redirect_target),
    .rs1_data        (fetch_rs1_data),
    .rs2_data        (fetch_rs2_data),
    .rs1_ready       (rs1_ex_ready && !(mem_bypass_en && ex_mem_w.rd == rs1_addr_w)),
    .rs2_ready       (rs2_ex_ready && !(mem_bypass_en && ex_mem_w.rd == rs2_addr_w)),
    .train           (train),
    .train_index     (id_ex_w.pc[8:2]),
    .train_counter   (train_counter),
    .imem_addr       (io_imemAddr),
    .imem_data       (io_imemData),
    .imem_ready      (io_imemReady),
    .out             (if_id_w)
  );

  // ── ID + regfile ──────────────────────────────────────────────────────
  // Read and compare speculatively. The qualified IF/ID instruction still
  // controls issue, the load-use interlock and retirement metadata.
  assign rs1_addr_w = if_id_w.instr[19:15];
  assign rs2_addr_w = if_id_w.instr[24:20];
  // A matching EX writer needs forwarding after issue. A MEM writer is
  // already visible on the write-first ports used by ID and the load lookup.
  assign rs1_match_ex = id_ex_w.rd != 5'd0 && id_ex_w.rd == rs1_addr_w;
  assign rs2_match_ex = id_ex_w.rd != 5'd0 && id_ex_w.rd == rs2_addr_w;
  assign rs1_ex_ready = !(id_ex_w.ctrl.reg_write && rs1_match_ex);
  assign rs2_ex_ready = !(id_ex_w.ctrl.reg_write && rs2_match_ex);

  id_stage u_id (
    .clock    (clock),
    .reset    (reset),
    .stall    (stall_id),
    .flush    (flush_id),
    .in       (if_id_w),
    .rs1_data (id_rs1_data),
    .rs2_data (id_rs2_data),
    .out      (id_ex_w)
  );

  reg_file u_rf (
    .clock    (clock),
    .reset    (reset),
    .rs1_addr (rs1_addr_w),
    .rs2_addr (rs2_addr_w),
    .rs1_data (id_rs1_data),
    .rs2_data (id_rs2_data),
    .rs1_array(fetch_rs1_data),
    .rs2_array(fetch_rs2_data),
    .w_en     (mem_bypass_en && !hold_mem_wb),
    .w_addr   (ex_mem_w.rd),
    .w_data   (mem_bypass_data)
  );

  // ── EX ────────────────────────────────────────────────────────────────
  load_word_t ready_word, pending_word;
  logic ready_eligible, pending_eligible, load_hit;
  logic [12:0] ready_sum;
  logic [11:0] preview_rhs;
  logic [9:0] add_row_q, pending_row, pending_row_q;
  logic addi, add_reg, add_preview_q, lw_producer;
  logic ready_ram_q, pending_base_q, ready_carry_q;
  logic [1:0] ready_lane_q;
  logic [3:0] aligned_lanes, pending_lanes_q;

  assign ready_sum = {1'b0, id_rs1_data[11:0]} + {1'b0, if_id_w.instr[31:20]};
  assign preview_rhs = if_id_w.instr[5] ? id_rs2_data[11:0] : if_id_w.instr[31:20];
  assign addi = if_id_w.instr[6:0] == 7'b0010011 && if_id_w.instr[14:12] == 0;
  assign add_reg = if_id_w.instr[6:0] == 7'b0110011 && if_id_w.instr[14:12] == 0 &&
                   if_id_w.instr[31:25] == 0;
  assign lw_producer = id_ex_w.ctrl.mem_read && id_ex_w.ctrl.mem_width == 2'd2;
  assign pending_row = lw_producer ? ready_word.data[11:2] : add_row_q;

  // For each access width, mark every legal starting byte in a word.
  // Shifting by the pending displacement also discards word crossings.
  always_comb begin
    case (if_id_w.instr[13:12])
      2'd0: aligned_lanes = 4'b1111;
      2'd1: aligned_lanes = 4'b0101;
      default: aligned_lanes = 4'b0001;
    endcase
  end

  always_ff @(posedge clock) begin
    if (!stall_id) begin
      // Only word bits of the preview are needed. EX checks the actual lane.
      add_row_q <= 10'((id_rs1_data[11:0] + preview_rhs) >> 2);
      add_preview_q <= rs1_ex_ready && (addi || (add_reg && rs2_ex_ready));
      ready_lane_q <= ready_sum[1:0];
      ready_carry_q <= ready_sum[12];
      ready_ram_q <= rs1_ex_ready && id_rs1_data[31:20] == 0 && aligned_lanes[ready_sum[1:0]];
      pending_lanes_q <= aligned_lanes >> if_id_w.instr[21:20];
      pending_base_q <= !rs1_ex_ready && (add_preview_q || lw_producer) &&
                        if_id_w.instr[31:22] == 0;
    end
  end

  load_predictor u_load_predictor (
    .clock           (clock),
    .reset           (reset),
    .capture         (!stall_id),
    .ready_row       (ready_sum[11:2]),
    .pending_row     (pending_row),
    .mem_addr        (io_dmemAddr),
    .mem_read        (io_dmemREn),
    .mem_wen         (io_dmemWEn),
    .mem_ready       (io_dmemReady),
    .mem_rdata       (io_dmemRData),
    .mem_wdata       (io_dmemWData),
    .ready_word      (ready_word),
    .pending_word    (pending_word),
    .pending_row_q   (pending_row_q),
    .ready_eligible  (ready_eligible),
    .pending_eligible(pending_eligible)
  );

  ex_stage u_ex (
    .clock           (clock),
    .reset           (reset),
    .stall           (stall_ex_mem),
    .in              (id_ex_w),
    .capture_operands(!stall_id),
    .id_rs1_match    (rs1_match_ex),
    .id_rs2_match    (rs2_match_ex),
    .ready_word      (ready_word),
    .pending_word    (pending_word),
    .pending_row     (pending_row_q),
    .ready_eligible  (ready_eligible),
    .pending_eligible(pending_eligible),
    .ready_ram       (ready_ram_q),
    .pending_base    (pending_base_q),
    .pending_lanes   (pending_lanes_q),
    .ready_lane      (ready_lane_q),
    .ready_carry     (ready_carry_q),
    .load_hit        (load_hit),
    .out             (ex_mem_w),
    .div_wait        (div_wait),
    .redirect        (redirect),
    .redirect_target (redirect_target),
    .train           (train),
    .train_counter   (train_counter)
  );

  // ── MEM ───────────────────────────────────────────────────────────────
  mem_stage u_mem (
    .clock      (clock),
    .reset      (reset),
    .hold_wb    (hold_mem_wb),
    .in         (ex_mem_w),
    .dmem_addr  (io_dmemAddr),
    .dmem_wdata (io_dmemWData),
    .dmem_rdata (io_dmemRData),
    .dmem_wen   (io_dmemWEn),
    .dmem_ren   (io_dmemREn),
    .bypass_en  (mem_bypass_en),
    .bypass_data(mem_bypass_data),
    .out        (mem_wb_w)
  );

  // ── Hazard / forwarding ───────────────────────────────────────────────
  hazard_unit u_hazard (
    .id_ex_mem_read (id_ex_w.ctrl.mem_read && !load_hit),
    .id_ex_rd       (id_ex_w.rd),
    .if_id_rs1      (rs1_addr_w),
    .if_id_rs2      (rs2_addr_w),
    .redirect       (redirect),
    .fetch_valid    (if_id_w.valid),
    .dmem_ready     (io_dmemReady),
    .ex_mem_mem_op  (io_dmemREn || (|io_dmemWEn)),
    .div_wait       (div_wait),
    .stall_if       (stall_if),
    .stall_id       (stall_id),
    .flush_id       (flush_id),
    .stall_ex_mem   (stall_ex_mem),
    .hold_mem_wb    (hold_mem_wb)
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
    io_rvfi_rd_wdata_0  = rd_wen ? mem_wb_w.rd_data : 32'b0;
    io_rvfi_pc_rdata_0  = mem_wb_w.pc;
    io_rvfi_pc_wdata_0  = mem_wb_w.pc_next;
    io_rvfi_mem_addr_0  = mem_wb_w.mem_addr;
    io_rvfi_mem_rmask_0 = mem_wb_w.mem_rmask;
    io_rvfi_mem_wmask_0 = mem_wb_w.mem_wmask;
    io_rvfi_mem_rdata_0 = mem_wb_w.mem_rdata;
    io_rvfi_mem_wdata_0 = mem_wb_w.mem_wdata;
  end

endmodule
