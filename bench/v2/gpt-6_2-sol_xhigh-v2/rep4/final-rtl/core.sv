// rtl/core.sv
//
// Top-level wiring for the 5-stage in-order RV32IM core.
//
// IF -> ID -> EX -> MEM -> WB. ID selects bypass sources for EX.
// Issue waits for unsupported load followers, arithmetic and dmem stalls.
//
// IO port names use the `io_*` Chisel-emit prefix so the existing
// formal/wrapper_si.sv and test/cosim/main.cpp bindings carry through
// byte-for-byte. RVFI port set is the single-channel set described in
// CLAUDE.md invariant 1 under `nret: 1` (declared in core.yaml). The
// orchestrator routes formal to wrapper_si.sv + checks_si.cfg and FPGA
// synth to fpga/core_bench_si.sv for this core. There is no channel 1.
//
// Ordinary instructions commit from MEM/WB. A completed divide commits
// from EX/MEM after older work has drained. Both use channel 0.
`ifndef CORE_PKG_DEFINED
  `include "core_pkg.sv"
`endif

module core (
  input  logic        clock,
  input  logic        reset,
  // imem
  output logic [31:0] io_imemAddr,
  input  logic [31:0] io_imemData,
  // Low readiness holds the bus address unless EX redirects. Fetch can
  // enqueue tagged predictions while the bus is held.
  input  logic        io_imemReady,
  // dmem
  output logic [31:0] io_dmemAddr,
  input  logic [31:0] io_dmemRData,
  output logic [31:0] io_dmemWData,
  output logic [3:0]  io_dmemWEn,
  output logic        io_dmemREn,
  // dmem bus backpressure. Drive 1 for zero-wait. Drive 0 to model
  // dStall — a memory op in EX/MEM holds MEM, EX and decode until the
  // bus delivers. MEM/WB captures a bubble and fetch can fill the queue.
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
  mem_wb_t divide_commit, commit;

  // hazard / forward
  logic       stall_id, load_use_hazard;
  logic       stall_ex_mem;
  logic       arithmetic_wait;
  logic       ex_write_eligible, mem_write_eligible;
  logic       load_in_ex;
  load_follower_t follower;
  load_response_t load_response;
  operand_sel_t rs1_sel, rs2_sel;

  // EX redirect
  logic        redirect, fence_i;
  logic        ex_direct_taken, recover_indirect;
  logic [31:0] ex_sequential_pc, ex_direct_target;
  logic        train_negative;
  logic [5:0]  train_index;
  branch_resolution_t branch;
  logic        branch_correction, recovery_pending;
  logic [5:0]  indirect_index;

  assign load_in_ex = id_ex_w.valid && id_ex_w.ctrl.mem_read && id_ex_w.rd != 5'b0;
  assign load_use_hazard = follower.interlock;
  assign stall_ex_mem = !io_dmemReady && (ex_mem_w.ctrl.mem_read || ex_mem_w.ctrl.mem_write);
  assign stall_id = stall_ex_mem || (arithmetic_wait && !branch_correction);

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
    .issue_hold      (stall_ex_mem || arithmetic_wait),
    .recovery_hold   (stall_ex_mem),
    .load_in_ex      (load_in_ex),
    .load_rd         (id_ex_w.rd),
    .load_word       (id_ex_w.ctrl.mem_width == 2'd2),
    .follower        (follower),
    .redirect        (redirect),
    .fence_i         (fence_i),
    .ex_direct_taken (ex_direct_taken),
    .recover_indirect (recover_indirect),
    .ex_sequential_pc  (ex_sequential_pc),
    .ex_direct_target  (ex_direct_target),
    .mem_indirect_target ({ex_mem_w.effective_addr[31:2], 2'b00}),
    .mem_indirect_index (indirect_index),
    .branch          (branch),
    .train_index     (train_index),
    .train_negative  (train_negative),
    .branch_correction (branch_correction),
    .recovery_pending_q (recovery_pending),
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
    .flush    ((load_use_hazard && !recovery_pending) || redirect),
    .in       (if_id_w),
    .rs1_addr (rs1_addr_w),
    .rs2_addr (rs2_addr_w),
    .rs1_data (rs1_data_w),
    .rs2_data (rs2_data_w),
    .rs1_sel  (rs1_sel),
    .rs2_sel  (rs2_sel),
    .load_compare (follower.compare),
    .load_address (follower.address),
    .load_rs1     (follower.rs1),
    .load_rs2     (follower.rs2),
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
    .in              (id_ex_w),
    .branch_correction (branch_correction),
    .fwd_ex_mem      (ex_mem_w.alu_result),
    .fwd_mem_wb      (mem_wb_w.write_value),
    .raw_load        (io_dmemRData),
    .load_response   (load_response),
    .out             (ex_mem_w),
    .write_eligible  (ex_write_eligible),
    .arithmetic_wait (arithmetic_wait),
    .redirect        (redirect),
    .fence_i         (fence_i),
    .direct_taken    (ex_direct_taken),
    .recover_indirect (recover_indirect),
    .sequential_pc   (ex_sequential_pc),
    .direct_target   (ex_direct_target),
    .indirect_index  (indirect_index),
    .branch          (branch),
    .train_index     (train_index),
    .train_negative  (train_negative)
  );

  // ── MEM ───────────────────────────────────────────────────────────────
  mem_stage u_mem (
    .clock      (clock),
    .reset      (reset),
    .hold_wb    (stall_ex_mem),
    .in         (ex_mem_w),
    .branch_taken (branch.taken),
    .dmem_addr  (io_dmemAddr),
    .dmem_wdata (io_dmemWData),
    .dmem_rdata (io_dmemRData),
    .dmem_wen   (io_dmemWEn),
    .dmem_ren   (io_dmemREn),
    .load_response (load_response),
    .write_eligible (mem_write_eligible),
    .divide_commit  (divide_commit),
    .out        (mem_wb_w)
  );

  // ── WB ────────────────────────────────────────────────────────────────
  // A divide enters MEM with an empty WB retirement slot. Its earlier
  // commit only changes the architectural write and RVFI, while EX still
  // uses the values in the two pipeline registers.
  assign commit = divide_commit.valid ? divide_commit : mem_wb_w;

  wb_stage u_wb (
    .in     (commit),
    .w_en   (wb_w_en),
    .w_addr (wb_w_addr),
    .w_data (wb_w_data)
  );

  // ── Hazard / forwarding ───────────────────────────────────────────────
  forward_unit u_fwd (
    .id_rs1             (rs1_addr_w),
    .id_rs2             (rs2_addr_w),
    .ex_rd              (id_ex_w.rd),
    .ex_write_eligible  (ex_write_eligible),
    .mem_rd             (ex_mem_w.rd),
    .mem_write_eligible (mem_write_eligible),
    .rs1_sel            (rs1_sel),
    .rs2_sel            (rs2_sel)
  );

  // ── RVFI ──────────────────────────────────────────────────────────────
  logic [63:0] rvfi_order_q;

  always_ff @(posedge clock) begin
    if (reset)             rvfi_order_q <= 64'b0;
    else if (commit.valid) rvfi_order_q <= rvfi_order_q + 64'b1;
  end

  always_comb begin
    io_rvfi_valid_0     = commit.valid;
    io_rvfi_order_0     = rvfi_order_q;
    io_rvfi_insn_0      = commit.instr;
    io_rvfi_trap_0      = commit.trap;
    io_rvfi_halt_0      = 1'b0;
    io_rvfi_intr_0      = 1'b0;
    io_rvfi_mode_0      = 2'd3;     // M-mode only
    io_rvfi_ixl_0       = 2'd1;     // 32-bit ISA
    io_rvfi_rs1_addr_0  = commit.rs1_addr;
    io_rvfi_rs1_rdata_0 = commit.rs1_val;
    io_rvfi_rs2_addr_0  = commit.rs2_addr;
    io_rvfi_rs2_rdata_0 = commit.rs2_val;
    io_rvfi_rd_addr_0   = wb_w_en ? wb_w_addr : 5'b0;
    io_rvfi_rd_wdata_0  = wb_w_en ? wb_w_data : 32'b0;
    io_rvfi_pc_rdata_0  = commit.pc;
    io_rvfi_pc_wdata_0  = commit.pc_next;
    io_rvfi_mem_addr_0  = commit.mem_addr;
    io_rvfi_mem_rmask_0 = commit.mem_rmask;
    io_rvfi_mem_wmask_0 = commit.mem_wmask;
    io_rvfi_mem_rdata_0 = commit.mem_rdata;
    io_rvfi_mem_wdata_0 = commit.mem_wdata;
  end

endmodule
