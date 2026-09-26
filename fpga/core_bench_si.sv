// fpga/core_bench_si.sv
//
// FPGA Fmax wrapper for single-issue (`nret 1`) cores. Same shape as
// core_bench.sv but instantiates `core` with only the channel-0 RVFI port
// set — no `_1` ports. Selected by the orchestrator (via BENCH env var in
// synth.tcl) when cores/<target>/core.yaml declares nret: 1.
//
// See core_bench.sv for the full rationale on LFSR-driven imem, dmem
// model, and the XOR-reduce LED that keeps RVFI fan-out alive through
// dead-output elimination.
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
  // Single-channel RVFI fan-out (NRET=1 contract).
  logic        rvfi_valid_0;
  logic [63:0] rvfi_order_0;
  logic [31:0] rvfi_insn_0, rvfi_pc_rdata_0, rvfi_pc_wdata_0;
  logic [31:0] rvfi_rd_wdata_0, rvfi_rs1_rdata_0, rvfi_rs2_rdata_0;
  logic [31:0] rvfi_mem_addr_0, rvfi_mem_rdata_0, rvfi_mem_wdata_0;
  logic [4:0]  rvfi_rs1_addr_0, rvfi_rs2_addr_0, rvfi_rd_addr_0;
  logic [3:0]  rvfi_mem_rmask_0, rvfi_mem_wmask_0;
  logic [1:0]  rvfi_mode_0, rvfi_ixl_0;
  logic        rvfi_trap_0, rvfi_halt_0, rvfi_intr_0;

  core cpu (
    .clock            (clock),
    .reset            (reset),
    .io_imemAddr      (imem_addr),
    .io_imemData      (lfsr),
    .io_imemReady     (1'b1),
    .io_dmemAddr      (dmem_addr),
    .io_dmemWData     (dmem_wdata),
    .io_dmemRData     (dmem_rdata),
    .io_dmemWEn       (dmem_wen),
    .io_dmemREn       (dmem_ren),
    .io_dmemReady     (1'b1),
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

  // XOR-reduce all CPU outputs to a single LED bit. Without this,
  // dead-output elimination would prune the RVFI fan-out.
  assign led = ^{rvfi_valid_0, rvfi_order_0, rvfi_insn_0, rvfi_trap_0, rvfi_halt_0, rvfi_intr_0,
                 rvfi_mode_0, rvfi_ixl_0, rvfi_rs1_addr_0, rvfi_rs1_rdata_0,
                 rvfi_rs2_addr_0, rvfi_rs2_rdata_0, rvfi_rd_addr_0, rvfi_rd_wdata_0,
                 rvfi_pc_rdata_0, rvfi_pc_wdata_0, rvfi_mem_addr_0,
                 rvfi_mem_rmask_0, rvfi_mem_wmask_0, rvfi_mem_rdata_0, rvfi_mem_wdata_0,
                 imem_addr, dmem_rdata};

endmodule
