// fpga/core_bench_si.sv
//
// FPGA Fmax wrapper for single-issue (`nret 1`) cores. Same shape as
// core_bench.sv but instantiates `core` with only the channel-0 RVFI port
// set — no `_1` ports. Selected by the orchestrator (via BENCH env var in
// synth.tcl) when cores/<target>/core.yaml declares nret: 1.
//
// See core_bench.sv for the rationale on LFSR-driven imem, the dmem
// model, the V2 stall generator, and why the LED observes only the
// memory-side outputs (RVFI-only logic is pruned).
module core_bench (
  input  logic clock,
  input  logic reset,
  output logic led
);

  logic [31:0] lfsr;
  always_ff @(posedge clock or posedge reset)
    if (reset) lfsr <= 32'h1;
    else       lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

  logic [31:0] dmem [0:2047];
  logic [31:0] dmem_rdata;
  logic [31:0] dmem_addr;
  logic [31:0] dmem_wdata;
  logic [3:0]  dmem_wen;
  logic        dmem_ren;

  always_ff @(posedge clock) begin
    if (dmem_wen[0]) dmem[dmem_addr[12:2]][7:0]   <= dmem_wdata[7:0];
    if (dmem_wen[1]) dmem[dmem_addr[12:2]][15:8]  <= dmem_wdata[15:8];
    if (dmem_wen[2]) dmem[dmem_addr[12:2]][23:16] <= dmem_wdata[23:16];
    if (dmem_wen[3]) dmem[dmem_addr[12:2]][31:24] <= dmem_wdata[31:24];
  end
  assign dmem_rdata = dmem[dmem_addr[12:2]];

  logic [31:0] imem_addr;
  // Single-channel RVFI port set (NRET=1 contract). Connected for
  // elaboration only; nothing observes it, so synthesis prunes it.
  logic        rvfi_valid_0;
  logic [63:0] rvfi_order_0;
  logic [31:0] rvfi_insn_0, rvfi_pc_rdata_0, rvfi_pc_wdata_0;
  logic [31:0] rvfi_rd_wdata_0, rvfi_rs1_rdata_0, rvfi_rs2_rdata_0;
  logic [31:0] rvfi_mem_addr_0, rvfi_mem_rdata_0, rvfi_mem_wdata_0;
  logic [4:0]  rvfi_rs1_addr_0, rvfi_rs2_addr_0, rvfi_rd_addr_0;
  logic [3:0]  rvfi_mem_rmask_0, rvfi_mem_wmask_0;
  logic [1:0]  rvfi_mode_0, rvfi_ixl_0;
  logic        rvfi_trap_0, rvfi_halt_0, rvfi_intr_0;

  // V2: memory-ready signals come from the same stall sequence the
  // CoreMark simulation uses, so stall-handling logic is part of the
  // timed netlist (fpga/bench_stall_gen.sv).
  logic imem_ready, dmem_ready;
  bench_stall_gen stall_gen (
    .clock      (clock),
    .reset      (reset),
    .imem_ready (imem_ready),
    .dmem_ready (dmem_ready)
  );

  core cpu (
    .clock            (clock),
    .reset            (reset),
    .io_imemAddr      (imem_addr),
    .io_imemData      (lfsr),
    .io_imemReady     (imem_ready),
    .io_dmemAddr      (dmem_addr),
    .io_dmemWData     (dmem_wdata),
    .io_dmemRData     (dmem_rdata),
    .io_dmemWEn       (dmem_wen),
    .io_dmemREn       (dmem_ren),
    .io_dmemReady     (dmem_ready),
    .io_rvfi_valid_0    (rvfi_valid_0),
    .io_rvfi_order_0    (rvfi_order_0),
    .io_rvfi_insn_0     (rvfi_insn_0),
    .io_rvfi_trap_0     (rvfi_trap_0),
    .io_rvfi_halt_0     (rvfi_halt_0),
    .io_rvfi_intr_0     (rvfi_intr_0),
    .io_rvfi_mode_0     (rvfi_mode_0),
    .io_rvfi_ixl_0      (rvfi_ixl_0),
    .io_rvfi_rs1_addr_0 (rvfi_rs1_addr_0),
    .io_rvfi_rs1_rdata_0(rvfi_rs1_rdata_0),
    .io_rvfi_rs2_addr_0 (rvfi_rs2_addr_0),
    .io_rvfi_rs2_rdata_0(rvfi_rs2_rdata_0),
    .io_rvfi_rd_addr_0  (rvfi_rd_addr_0),
    .io_rvfi_rd_wdata_0 (rvfi_rd_wdata_0),
    .io_rvfi_pc_rdata_0 (rvfi_pc_rdata_0),
    .io_rvfi_pc_wdata_0 (rvfi_pc_wdata_0),
    .io_rvfi_mem_addr_0 (rvfi_mem_addr_0),
    .io_rvfi_mem_rmask_0(rvfi_mem_rmask_0),
    .io_rvfi_mem_wmask_0(rvfi_mem_wmask_0),
    .io_rvfi_mem_rdata_0(rvfi_mem_rdata_0),
    .io_rvfi_mem_wdata_0(rvfi_mem_wdata_0)
  );

  // V2: observe only the memory-side outputs. Everything the core computes
  // reaches the fetch address or a store, so the datapath stays in the
  // netlist; logic that only drives RVFI (a verification port a deployed
  // core would not have) is pruned and does not count toward Fmax or area.
  assign led = ^{imem_addr, dmem_addr, dmem_wdata, dmem_wen, dmem_ren, dmem_rdata};

endmodule
