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
  logic        rvfi_valid;
  logic [63:0] rvfi_order;
  logic [31:0] rvfi_insn, rvfi_pc_rdata, rvfi_pc_wdata;
  logic [31:0] rvfi_rd_wdata, rvfi_rs1_rdata, rvfi_rs2_rdata;
  logic [31:0] rvfi_mem_addr, rvfi_mem_rdata, rvfi_mem_wdata;
  logic [4:0]  rvfi_rs1_addr, rvfi_rs2_addr, rvfi_rd_addr;
  logic [3:0]  rvfi_mem_rmask, rvfi_mem_wmask;
  logic [1:0]  rvfi_mode, rvfi_ixl;
  logic        rvfi_trap, rvfi_halt, rvfi_intr;

  core cpu (
    .clock            (clock),
    .reset            (reset),
    .io_imemAddr      (imem_addr),
    .io_imemData      (lfsr),                  // LFSR drives instr fetch
    .io_dmemAddr      (dmem_addr),
    .io_dmemWData     (dmem_wdata),
    .io_dmemRData     (dmem_rdata),
    .io_dmemWEn       (dmem_wen),
    .io_dmemREn       (dmem_ren),
    .io_rvfi_valid    (rvfi_valid),
    .io_rvfi_order    (rvfi_order),
    .io_rvfi_insn     (rvfi_insn),
    .io_rvfi_trap     (rvfi_trap),
    .io_rvfi_halt     (rvfi_halt),
    .io_rvfi_intr     (rvfi_intr),
    .io_rvfi_mode     (rvfi_mode),
    .io_rvfi_ixl      (rvfi_ixl),
    .io_rvfi_rs1_addr (rvfi_rs1_addr),
    .io_rvfi_rs1_rdata(rvfi_rs1_rdata),
    .io_rvfi_rs2_addr (rvfi_rs2_addr),
    .io_rvfi_rs2_rdata(rvfi_rs2_rdata),
    .io_rvfi_rd_addr  (rvfi_rd_addr),
    .io_rvfi_rd_wdata (rvfi_rd_wdata),
    .io_rvfi_pc_rdata (rvfi_pc_rdata),
    .io_rvfi_pc_wdata (rvfi_pc_wdata),
    .io_rvfi_mem_addr (rvfi_mem_addr),
    .io_rvfi_mem_rmask(rvfi_mem_rmask),
    .io_rvfi_mem_wmask(rvfi_mem_wmask),
    .io_rvfi_mem_rdata(rvfi_mem_rdata),
    .io_rvfi_mem_wdata(rvfi_mem_wdata)
  );

  // XOR-reduce all CPU outputs to a single LED bit. Without this,
  // dead-output elimination would prune the RVFI fan-out (and most of
  // the pipeline registers) since their values aren't visible at the
  // top-level pin list.
  assign led = ^{rvfi_valid, rvfi_order, rvfi_insn, rvfi_trap, rvfi_halt, rvfi_intr,
                 rvfi_mode, rvfi_ixl, rvfi_rs1_addr, rvfi_rs1_rdata,
                 rvfi_rs2_addr, rvfi_rs2_rdata, rvfi_rd_addr, rvfi_rd_wdata,
                 rvfi_pc_rdata, rvfi_pc_wdata, rvfi_mem_addr,
                 rvfi_mem_rmask, rvfi_mem_wmask, rvfi_mem_rdata, rvfi_mem_wdata,
                 imem_addr, dmem_rdata};

endmodule
