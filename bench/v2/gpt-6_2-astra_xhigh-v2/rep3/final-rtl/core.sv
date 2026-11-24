// rtl/core.sv
//
// Top-level wiring for the 5-stage in-order RV32IM core.
//
//  IF -> ID -> EX -> MEM -> WB
//   |    |     ^
//   |    +-----+    ID registers the operand values and bypass selects for EX
//   +- stall <- hazard_unit (late result use)
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
// RVFI fields:    all of them — driven from the MEM/WB register.
module core (
  input  logic        clock,
  input  logic        reset,
  // imem
  output logic [31:0] io_imemAddr,
  input  logic [31:0] io_imemData,
  // imem bus backpressure. Drive 1 for zero-wait single-cycle BRAM (the
  // V0 default). When low, IF can reuse a matching saved instruction.
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
  // dmem bus backpressure. Drive 1 for zero-wait. Drive 0 to model
  // dStall — demand loads and stores hold MEM until the bus accepts them.
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
  logic       stall_if, stall_id, replay;
  logic       stall_ex_mem, hold_mem_wb, div_wait;
  logic       id_ex_mul, mul_in_ex, div_in_ex;
  logic [31:0] mem_product, div_result, mem_div_result_q;
  logic       ex_writes_rd, mem_writes_rd;
  logic [1:0] id_fwd_rs1, id_fwd_rs2;
  logic [2:0] fwd_rs1_sel_q, fwd_rs2_sel_q;

  // EX redirect
  logic        redirect;
  logic        forecast_used;
  logic [31:0] forecast_pc;
  logic [31:0] fallthrough_pc;
  logic        train_en;
  logic [5:0]  train_index;
  logic [1:0]  train_value;

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
    .stall_id        (stall_id),
    .replay          (replay),
    .imem_ready      (io_imemReady),
    .redirect        (redirect),
    .resolved_pc     (ex_mem_w.pc_next),
    .fence_i         (id_ex_w.valid && id_ex_w.instr[6:0] == 7'h0f &&
                      id_ex_w.instr[14:12] == 3'b001),
    .train_en        (train_en),
    .train_index     (train_index),
    .train_value     (train_value),
    .mem_transfer    (ex_mem_w.valid && !hold_mem_wb),
    .mem_pc          (ex_mem_w.pc),
    .mem_instr       (ex_mem_w.instr),
    .forecast_used   (forecast_used),
    .forecast_pc     (forecast_pc),
    .fallthrough_q   (fallthrough_pc),
    .imem_addr       (io_imemAddr),
    .imem_data       (io_imemData),
    .out             (if_id_w)
  );

  // ── ID + regfile ──────────────────────────────────────────────────────
  id_stage u_id (
    .clock    (clock),
    .reset    (reset),
    .stall    (stall_id),
    .squash   (redirect || replay),
    .in       (if_id_w),
    .rs1_addr (rs1_addr_w),
    .rs2_addr (rs2_addr_w),
    .rs1_data (id_fwd_rs1 == 0 ? rs1_data_w : 32'b0),
    .rs2_data (id_fwd_rs2 == 0 ? rs2_data_w : 32'b0),
    .is_mul   (id_ex_mul),
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

  // ── Load buffer ───────────────────────────────────────────────────────
  // The ID port guesses a row one stage before address generation. EX
  // compares that response's whole word address and probes a second port
  // with the actual index. Only the resolved port can satisfy MEM.
  typedef struct packed {
    logic        valid;
    logic [7:0]  tag;
    logic [31:0] word_data;
  } load_row_t;
  load_row_t rows [0:1023];
  load_row_t early_row_q, resolved_row_q;
  logic [9:0] base_index, predicted_index, early_index_q;
  logic [9:0] sweep_index_q, write_index;
  logic [31:0] ex_addr, read_word;
  logic sweep_q, update_row, read_request, ex_ram_load;
  logic early_available_q, resolved_available_q, early_hit, resolved_hit;

  // Keep both the hit check and the address adder off the ID index path.
  // Even stale data is a safe pointer hint until EX verifies the row.
  always_comb begin
    base_index = rs1_data_w[11:2];
    if (ex_mem_w.ctrl.reg_write && ex_mem_w.rd != 0 && ex_mem_w.rd == rs1_addr_w)
      base_index = ex_mem_w.alu_result[11:2];
    if (id_ex_w.ctrl.mem_read && id_ex_w.rd != 0 && id_ex_w.rd == rs1_addr_w)
      base_index = early_row_q.word_data[11:2];
  end
  assign predicted_index = base_index ^ if_id_w.instr[31:22];

  always_ff @(posedge clock) begin
    if (reset) begin
      sweep_q       <= 1'b1;
      sweep_index_q <= '0;
    end else if (sweep_q) begin
      sweep_index_q <= sweep_index_q + 1'b1;
      if (&sweep_index_q) sweep_q <= 1'b0;
    end
  end

  assign update_row = sweep_q || (io_dmemReady && ex_mem_w.mem_addr[31:20] == 0 &&
                                  (io_dmemREn || (|io_dmemWEn)));
  assign write_index = sweep_q ? sweep_index_q : ex_mem_w.mem_addr[11:2];
  always_ff @(posedge clock) begin
    if (update_row)
      rows[write_index] <= {!sweep_q && (io_dmemREn || (&io_dmemWEn)),
                            ex_mem_w.mem_addr[19:12], io_dmemREn ? io_dmemRData : io_dmemWData};
    else if (!stall_id)
      early_row_q <= rows[predicted_index];
    if (!stall_ex_mem)
      resolved_row_q <= rows[ex_addr[11:2]];
  end

  // Qualify the resolved port in EX so MEM only needs its tag comparison.
  assign ex_ram_load = id_ex_w.ctrl.mem_read && ex_addr[31:20] == 0 &&
                       naturally_aligned(id_ex_w.ctrl.mem_width, ex_addr[1:0]);
  always_ff @(posedge clock) begin
    if (!stall_id) begin
      early_index_q     <= predicted_index;
      early_available_q <= !update_row;
    end
    if (!stall_ex_mem)
      resolved_available_q <= ex_ram_load && !sweep_q && !(update_row && write_index == ex_addr[11:2]);
  end

  // Veto the early bypass when the upcoming resolved read collides with
  // a write. This also covers a store accepted after a multi-cycle hold.
  assign early_hit = ex_ram_load && early_available_q && early_row_q.valid &&
                     ex_addr[19:2] == {early_row_q.tag, early_index_q} &&
                     !(update_row && write_index == early_index_q);
  assign resolved_hit = resolved_available_q && resolved_row_q.valid &&
                        ex_mem_w.mem_addr[19:12] == resolved_row_q.tag;
  assign io_dmemREn = read_request && !resolved_hit;
  assign read_word  = resolved_hit ? resolved_row_q.word_data : io_dmemRData;

  // ── EX ────────────────────────────────────────────────────────────────
  assign mul_in_ex = id_ex_w.valid && id_ex_mul;

  ex_stage u_ex (
    .clock           (clock),
    .reset           (reset),
    .stall           (stall_ex_mem),
    .in              (id_ex_w),
    .is_mul          (mul_in_ex),
    .fallthrough_pc  (fallthrough_pc),
    .mem_product     (mem_product),
    .is_div          (div_in_ex),
    .div_result      (div_result),
    .early_word      (early_row_q.word_data),
    .mem_addr        (ex_addr),
    .fwd_rs1_sel     (fwd_rs1_sel_q),
    .fwd_rs2_sel     (fwd_rs2_sel_q),
    .fwd_ex_mem      (ex_mem_w.alu_result),  // EX/MEM-registered ALU result
    .fwd_mem_wb      (wb_w_data),            // MEM/WB-registered write data
    .forecast_used   (forecast_used),
    .forecast_pc     (forecast_pc),
    .out             (ex_mem_w),
    .writes_rd       (ex_writes_rd),
    .div_wait        (div_wait),
    .redirect        (redirect),
    .train_en        (train_en),
    .train_index     (train_index),
    .train_value     (train_value)
  );

  // ── MEM ───────────────────────────────────────────────────────────────
  always_ff @(posedge clock) begin
    if (div_in_ex && !div_wait && !stall_ex_mem)
      mem_div_result_q <= div_result;
  end

  mem_stage u_mem (
    .clock      (clock),
    .reset      (reset),
    .hold_wb    (hold_mem_wb),
    .in         (ex_mem_w),
    .mem_product(mem_product),
    .div_result (mem_div_result_q),
    .dmem_addr  (io_dmemAddr),
    .dmem_wdata (io_dmemWData),
    .read_word  (read_word),
    .dmem_wen   (io_dmemWEn),
    .read_request(read_request),
    .writes_rd  (mem_writes_rd),
    .out        (mem_wb_w)
  );

  // ── WB ────────────────────────────────────────────────────────────────
  wb_stage u_wb (
    .in     (mem_wb_w),
    .w_en   (wb_w_en),
    .w_addr (wb_w_addr),
    .w_data (wb_w_data)
  );

  // ── Hazard / forwarding ───────────────────────────────────────────────
  hazard_unit u_hazard (
    .clock          (clock),
    .reset          (reset),
    .id_ex_mem_result ((id_ex_w.valid && id_ex_w.ctrl.mem_read) || div_in_ex),
    .bypass_ready   (early_hit && id_ex_w.ctrl.mem_read),
    .id_ex_rd       (id_ex_w.rd),
    .if_id_rs1      (if_id_w.instr[19:15]),
    .if_id_rs2      (if_id_w.instr[24:20]),
    .div_wait       (div_wait),
    .imem_ready     (if_id_w.valid), // bus word or matching saved instruction
    .dmem_ready     (io_dmemReady),
    .ex_mem_mem_op  (io_dmemREn || ex_mem_w.ctrl.mem_write),
    .stall_if       (stall_if),
    .stall_id       (stall_id),
    .replay         (replay),
    .stall_ex_mem   (stall_ex_mem),
    .hold_mem_wb    (hold_mem_wb)
  );

  forward_unit u_fwd (
    .id_rs1   (rs1_addr_w),
    .id_rs2   (rs2_addr_w),
    .ex_rd    (id_ex_w.rd),
    .ex_w_en  (ex_writes_rd),
    .mem_rd   (ex_mem_w.rd),
    .mem_w_en (mem_writes_rd),
    .fwd_rs1  (id_fwd_rs1),
    .fwd_rs2  (id_fwd_rs2)
  );

  // Split the youngest EX match by result type before latching it.
  // On a match, ID has already zeroed the register-file contribution.
  always_ff @(posedge clock) begin
    if (!stall_id) begin
      fwd_rs1_sel_q <= {id_fwd_rs1[1], id_fwd_rs1[0] && mul_in_ex,
                        id_fwd_rs1[0] && !mul_in_ex};
      fwd_rs2_sel_q <= {id_fwd_rs2[1], id_fwd_rs2[0] && mul_in_ex,
                        id_fwd_rs2[0] && !mul_in_ex};
    end
  end

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
