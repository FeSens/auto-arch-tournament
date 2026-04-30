// fpga/core_bench.sv
//
// FPGA synthesis wrapper for Fmax benchmarking. Drives `core` directly
// (rather than the deployable SoC) so:
//
//   1. The CPU's critical path is what gets timed — synthesizing an SoC
//      with zero-initialized BRAM imem/dmem lets Yosys constant-fold the
//      pipeline to "always retire illegal opcode 0", pruning ~99% of the
//      logic. Fmax then has no relation to the real critical path.
//
//   2. Driving io_imemData from a 32-bit LFSR forces non-constant fetch
//      data, so the decoder, ALU, imm_gen, branch comparator, and
//      forwarding muxes all stay in the netlist for timing.
//
// dmem mirrors the deployable SoC (8 KiB, byte-lane writeable) so the
// dmem read mux's LUT/BRAM map matches what the eventual deployment will
// see. The XOR-reduce LED retains every RVFI fan-out so the rvfi register
// chain isn't dead-code-eliminated.
//
// Module is `core_bench` (lowercase) to match the project's "module name
// = file name" rule. The synth.tcl script reads rtl/*.sv first so this
// file's `core` instantiation resolves correctly.
module core_bench (
  input  logic clock,
  input  logic reset,
  output logic led
);

  // 32-bit Fibonacci LFSR. Tap selection keeps it full-period for any
  // non-zero seed so io_imemData looks random to the synthesizer.
  logic [31:0] lfsr;
  always_ff @(posedge clock or posedge reset)
    if (reset) lfsr <= 32'h1;
    else       lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

  // 8 KiB dmem (2K words, byte-lane writeable). Keeps the dmem read path
  // representative of the real SoC's BRAM-mapped memory.
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
  // Combinational read — matches core's expected io_dmemRData semantics.
  assign dmem_rdata = dmem[dmem_addr[12:2]];

  logic [31:0] imem_addr;
  // 2-channel RVFI fan-out (NRET=2 contract). V0 channel 1 is constants
  // from core, but the parallel decl + XOR include keeps the harness
  // identical for future dual-issue hypotheses.
  logic        rvfi_valid_0, rvfi_valid_1;
  logic [63:0] rvfi_order_0, rvfi_order_1;
  logic [31:0] rvfi_insn_0, rvfi_pc_rdata_0, rvfi_pc_wdata_0;
  logic [31:0] rvfi_insn_1, rvfi_pc_rdata_1, rvfi_pc_wdata_1;
  logic [31:0] rvfi_rd_wdata_0, rvfi_rs1_rdata_0, rvfi_rs2_rdata_0;
  logic [31:0] rvfi_rd_wdata_1, rvfi_rs1_rdata_1, rvfi_rs2_rdata_1;
  logic [31:0] rvfi_mem_addr_0, rvfi_mem_rdata_0, rvfi_mem_wdata_0;
  logic [31:0] rvfi_mem_addr_1, rvfi_mem_rdata_1, rvfi_mem_wdata_1;
  logic [4:0]  rvfi_rs1_addr_0, rvfi_rs2_addr_0, rvfi_rd_addr_0;
  logic [4:0]  rvfi_rs1_addr_1, rvfi_rs2_addr_1, rvfi_rd_addr_1;
  logic [3:0]  rvfi_mem_rmask_0, rvfi_mem_wmask_0;
  logic [3:0]  rvfi_mem_rmask_1, rvfi_mem_wmask_1;
  logic [1:0]  rvfi_mode_0, rvfi_ixl_0;
  logic [1:0]  rvfi_mode_1, rvfi_ixl_1;
  logic        rvfi_trap_0, rvfi_halt_0, rvfi_intr_0;
  logic        rvfi_trap_1, rvfi_halt_1, rvfi_intr_1;

  core cpu (
    .clock            (clock),
    .reset            (reset),
    .io_imemAddr      (imem_addr),
    .io_imemData      (lfsr),                  // LFSR drives instr fetch
    // FPGA target uses 1-cycle BRAM, modelled here as zero-wait. The
    // ready ports exist only so the cosim's stall-mode (vex_main.cpp)
    // can drive them; on silicon they're permanently asserted.
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
    .io_rvfi_mem_wdata_0(rvfi_mem_wdata_0),
    .io_rvfi_valid_1    (rvfi_valid_1),
    .io_rvfi_order_1    (rvfi_order_1),
    .io_rvfi_insn_1     (rvfi_insn_1),
    .io_rvfi_trap_1     (rvfi_trap_1),
    .io_rvfi_halt_1     (rvfi_halt_1),
    .io_rvfi_intr_1     (rvfi_intr_1),
    .io_rvfi_mode_1     (rvfi_mode_1),
    .io_rvfi_ixl_1      (rvfi_ixl_1),
    .io_rvfi_rs1_addr_1 (rvfi_rs1_addr_1),
    .io_rvfi_rs1_rdata_1(rvfi_rs1_rdata_1),
    .io_rvfi_rs2_addr_1 (rvfi_rs2_addr_1),
    .io_rvfi_rs2_rdata_1(rvfi_rs2_rdata_1),
    .io_rvfi_rd_addr_1  (rvfi_rd_addr_1),
    .io_rvfi_rd_wdata_1 (rvfi_rd_wdata_1),
    .io_rvfi_pc_rdata_1 (rvfi_pc_rdata_1),
    .io_rvfi_pc_wdata_1 (rvfi_pc_wdata_1),
    .io_rvfi_mem_addr_1 (rvfi_mem_addr_1),
    .io_rvfi_mem_rmask_1(rvfi_mem_rmask_1),
    .io_rvfi_mem_wmask_1(rvfi_mem_wmask_1),
    .io_rvfi_mem_rdata_1(rvfi_mem_rdata_1),
    .io_rvfi_mem_wdata_1(rvfi_mem_wdata_1)
  );

  // XOR-reduce all CPU outputs to a single LED bit. Without this,
  // dead-output elimination would prune the RVFI fan-out (and most of
  // the pipeline registers) since their values aren't visible at the
  // top-level pin list.
  assign led = ^{rvfi_valid_0, rvfi_order_0, rvfi_insn_0, rvfi_trap_0, rvfi_halt_0, rvfi_intr_0,
                 rvfi_mode_0, rvfi_ixl_0, rvfi_rs1_addr_0, rvfi_rs1_rdata_0,
                 rvfi_rs2_addr_0, rvfi_rs2_rdata_0, rvfi_rd_addr_0, rvfi_rd_wdata_0,
                 rvfi_pc_rdata_0, rvfi_pc_wdata_0, rvfi_mem_addr_0,
                 rvfi_mem_rmask_0, rvfi_mem_wmask_0, rvfi_mem_rdata_0, rvfi_mem_wdata_0,
                 rvfi_valid_1, rvfi_order_1, rvfi_insn_1, rvfi_trap_1, rvfi_halt_1, rvfi_intr_1,
                 rvfi_mode_1, rvfi_ixl_1, rvfi_rs1_addr_1, rvfi_rs1_rdata_1,
                 rvfi_rs2_addr_1, rvfi_rs2_rdata_1, rvfi_rd_addr_1, rvfi_rd_wdata_1,
                 rvfi_pc_rdata_1, rvfi_pc_wdata_1, rvfi_mem_addr_1,
                 rvfi_mem_rmask_1, rvfi_mem_wmask_1, rvfi_mem_rdata_1, rvfi_mem_wdata_1,
                 imem_addr, dmem_rdata};

endmodule
