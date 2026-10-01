// rtl/core.sv
//
// Top-level wiring for the 5-stage in-order RV32IM core.
//
//  IF -> ID -> EX -> MEM -> WB
//   |    |     ^
//   |    +-----+    registered forwarding selects drive EX operand muxes
//   |               from EX/MEM and MEM/WB
//   +- stall <- hazard_unit (load-use)
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
//                 the registered WB-stage write value.
`include "core_pkg.sv"
module core (
  input  logic        clock,
  input  logic        reset,
  // imem
  output logic [31:0] io_imemAddr,
  input  logic [31:0] io_imemData,
  // imem bus backpressure. Drive 1 for zero-wait single-cycle BRAM (the
  // V0 default). Drive 0 to model bus stall — PC reg holds, IF/ID
  // payload becomes a NOP, and a pipeline bubble propagates downstream.
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
  // dStall — when there is a memory op in EX/MEM, the entire pipeline
  // freezes back to MEM; MEM/WB captures a bubble; the LOAD/STORE waits
  // until the bus delivers.
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
  logic       stall_if, stall_id, flush_if, flush_id;
  logic       stall_ex_mem, hold_mem_wb;
  logic       divide_hold;
  logic [1:0] fwd_rs1_sel, fwd_rs2_sel;
  // One-hot EX/MEM banks plus MEM/WB and the held ID/EX value. These
  // controls cross the same edge as their producer and consumer payloads.
  logic [21:0] fwd_rs1_enable, fwd_rs2_enable;
  logic [19:0] producer_bank_enable;
  logic       fwd_select_hold;
  logic       ex_next_reg_write, mem_next_reg_write;
  logic [31:0] ex_mem_forward;
  logic [31:0] ex_mem_pc_next;

  // EX/MEM carries independent next-PC candidates and a narrow selector.
  // The older instruction redirects fetch from MEM in the following cycle.
  logic        mem_correction;
  logic        branch_train_valid;
  logic [4:0]  branch_train_index;
  logic        branch_train_taken;
  logic        replay_hit;
  logic        store_fetch_conflict;
  logic        store_completed;
  logic        fetch_ready;

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
    .flush           (flush_if),
    .redirect        (mem_correction),
    .redirect_target (ex_mem_pc_next),
    .train_valid     (branch_train_valid),
    .train_index     (branch_train_index),
    .train_taken     (branch_train_taken),
    .imem_ready      (io_imemReady),
    .store_valid     (store_completed),
    .store_word_addr (io_dmemAddr[31:2]),
    .replay_hit      (replay_hit),
    .store_fetch_conflict (store_fetch_conflict),
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
    .mem_correction  (mem_correction),
    .divide_hold     (divide_hold),
    .in              (id_ex_w),
    .fwd_select_hold (fwd_select_hold),
    .fwd_rs1_enable  (fwd_rs1_enable),
    .fwd_rs2_enable  (fwd_rs2_enable),
    .fwd_ex_mem      (ex_mem_w),             // independent registered banks
    .fwd_mem_wb      (wb_w_data),            // selected MEM/WB register
    .out             (ex_mem_w),
    .next_reg_write  (ex_next_reg_write),
    .branch_train_valid (branch_train_valid),
    .branch_train_index (branch_train_index),
    .branch_train_taken (branch_train_taken)
  );

  // ── MEM ───────────────────────────────────────────────────────────────
  mem_stage u_mem (
    .clock      (clock),
    .reset      (reset),
    .hold_wb    (hold_mem_wb),
    .in         (ex_mem_w),
    .selected_result (ex_mem_forward),
    .resolved_pc (ex_mem_pc_next),
    .dmem_addr  (io_dmemAddr),
    .dmem_wdata (io_dmemWData),
    .dmem_rdata (io_dmemRData),
    .dmem_wen   (io_dmemWEn),
    .dmem_ren   (io_dmemREn),
    .next_reg_write (mem_next_reg_write),
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
  assign store_completed = ex_mem_w.valid && io_dmemReady &&
                           (|io_dmemWEn);
  assign fetch_ready = (io_imemReady || replay_hit) &&
                       !store_fetch_conflict;
  hazard_unit u_hazard (
    .id_ex_mem_read (id_ex_w.ctrl.mem_read),
    .id_ex_rd       (id_ex_w.rd),
    .if_id_rs1      (if_id_w.instr[19:15]),
    .if_id_rs2      (if_id_w.instr[24:20]),
    .if_id_valid    (if_id_w.valid),
    .redirect       (mem_correction),
    .imem_ready     (fetch_ready),
    .dmem_ready     (io_dmemReady),
    .ex_mem_mem_op  (ex_mem_w.ctrl.mem_read | ex_mem_w.ctrl.mem_write),
    .divide_hold    (divide_hold),
    .stall_if       (stall_if),
    .stall_id       (stall_id),
    .flush_if       (flush_if),
    .flush_id       (flush_id),
    .stall_ex_mem   (stall_ex_mem),
    .hold_mem_wb    (hold_mem_wb)
  );

  // These selectors are speculative metadata for the instruction entering
  // ID/EX at this edge. Its potential producers are the current ID/EX and
  // EX/MEM instructions, which enter EX/MEM and MEM/WB respectively. A
  // flush replaces the consumer with a bubble, making its select irrelevant.
  // A data-memory stall instead holds the consumer and both producers, so
  // retain the selectors until the pipeline advances on the release edge.
  // Use the effective write enables to exclude faulting jumps and memory
  // operations, whose register writes are suppressed by their stages.
  always_comb begin
    fwd_rs1_sel = 2'd0;
    if (ex_next_reg_write && id_ex_w.rd != 5'b0 &&
        id_ex_w.rd == if_id_w.instr[19:15])
      fwd_rs1_sel = 2'd1;
    else if (mem_next_reg_write && ex_mem_w.rd != 5'b0 &&
             ex_mem_w.rd == if_id_w.instr[19:15])
      fwd_rs1_sel = 2'd2;

    fwd_rs2_sel = 2'd0;
    if (ex_next_reg_write && id_ex_w.rd != 5'b0 &&
        id_ex_w.rd == if_id_w.instr[24:20])
      fwd_rs2_sel = 2'd1;
    else if (mem_next_reg_write && ex_mem_w.rd != 5'b0 &&
             ex_mem_w.rd == if_id_w.instr[24:20])
      fwd_rs2_sel = 2'd2;
  end

  // Bit 19 selects the jump link; bits 18:0 select the producer's ALU
  // operation. Only the winning producer's controls enter each vector.
  assign producer_bank_enable = id_ex_w.ctrl.is_jump
      ? 20'h8_0000 : (20'b1 << id_ex_w.ctrl.alu_op);
  always_comb begin
    fwd_rs1_enable = '0;
    case (fwd_rs1_sel)
      2'd1: fwd_rs1_enable[19:0] = producer_bank_enable;
      2'd2: fwd_rs1_enable[20] = 1'b1;
      default: fwd_rs1_enable[21] = 1'b1;
    endcase
    fwd_rs2_enable = '0;
    case (fwd_rs2_sel)
      2'd1: fwd_rs2_enable[19:0] = producer_bank_enable;
      2'd2: fwd_rs2_enable[20] = 1'b1;
      default: fwd_rs2_enable[21] = 1'b1;
    endcase
  end

  assign fwd_select_hold = !io_dmemReady &&
                           (ex_mem_w.ctrl.mem_read || ex_mem_w.ctrl.mem_write);

  assign mem_correction = ex_mem_w.valid && ex_mem_w.correction_valid;

  // Both selections consume only registered EX/MEM data. A dependent ALU
  // instruction can issue on the next cycle with no extra pipeline stage.
  always_comb begin
    ex_mem_forward = 32'b0;
    if (ex_mem_w.ctrl.is_jump) begin
      ex_mem_forward = ex_mem_w.link_result;
    end else begin
      ex_mem_forward =
          ({32{ex_mem_w.forward_op[ALU_ADD]}}  & ex_mem_w.add_result) |
          ({32{ex_mem_w.forward_op[ALU_SUB]}}  & ex_mem_w.sub_result) |
          ({32{ex_mem_w.forward_op[ALU_AND]}}  & ex_mem_w.and_result) |
          ({32{ex_mem_w.forward_op[ALU_OR]}}   & ex_mem_w.or_result) |
          ({32{ex_mem_w.forward_op[ALU_XOR]}}  & ex_mem_w.xor_result) |
          ({32{ex_mem_w.forward_op[ALU_SLT]}}  & {31'b0, ex_mem_w.slt_result}) |
          ({32{ex_mem_w.forward_op[ALU_SLTU]}} & {31'b0, ex_mem_w.sltu_result}) |
          ({32{ex_mem_w.forward_op[ALU_SLL]}}  & ex_mem_w.sll_result) |
          ({32{ex_mem_w.forward_op[ALU_SRL]}}  & ex_mem_w.srl_result) |
          ({32{ex_mem_w.forward_op[ALU_SRA]}}  & ex_mem_w.sra_result) |
          ({32{ex_mem_w.forward_op[ALU_LUI]}}  & ex_mem_w.lui_result) |
`ifdef RISCV_FORMAL_ALTOPS
          ({32{(|ex_mem_w.forward_op[18:11])}} & ex_mem_w.alt_result);
`else
          ({32{ex_mem_w.forward_op[ALU_MUL]}}    & ex_mem_w.mul_result) |
          ({32{ex_mem_w.forward_op[ALU_MULH]}}   & ex_mem_w.mulh_result) |
          ({32{ex_mem_w.forward_op[ALU_MULHU]}}  & ex_mem_w.mulhu_result) |
          ({32{ex_mem_w.forward_op[ALU_MULHSU]}} & ex_mem_w.mulhsu_result) |
          ({32{(|ex_mem_w.forward_op[18:15])}}   & ex_mem_w.div_result);
`endif
    end
    case (ex_mem_w.pc_select)
      2'd1: ex_mem_pc_next = ex_mem_w.pc_direct;
      2'd2: ex_mem_pc_next = ex_mem_w.pc_jalr;
      default: ex_mem_pc_next = ex_mem_w.pc_sequential;
    endcase
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
