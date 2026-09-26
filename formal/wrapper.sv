// riscv-formal wrapper for `core`. Drives imem with symbolic data so the
// solver can pick any 32-bit instruction word each cycle, backs dmem with
// a concrete register array (8 KiB), and wires every RVFI output into
// the riscv-formal harness via the RVFI_OUTPUTS macro.
//
// CLAUDE.md invariants 1, 4, 5 are enforced here transitively: the
// checker framework reads rvfi_valid/order/etc. straight from this
// instance and runs the insn / reg / pc_fwd / pc_bwd / causal / unique /
// liveness / cover / ill checks against a free-running symbolic stream.
`include "rvfi_macros.vh"

module rvfi_wrapper (
    input clock,
    input reset,
    `RVFI_OUTPUTS
);
    // Solver picks any 32-bit instruction each cycle.
    (* keep *) `rvformal_rand_reg [31:0] imem_data;

    // 8 KiB dmem (2048 words).
    reg [31:0] dmem [0:2047];

    wire [31:0] imem_addr;
    wire [31:0] dmem_addr;
    wire [31:0] dmem_wdata;
    wire [3:0]  dmem_wen;
    wire        dmem_ren;

    always @(posedge clock) begin
        if (dmem_wen[0]) dmem[dmem_addr[12:2]][7:0]   <= dmem_wdata[7:0];
        if (dmem_wen[1]) dmem[dmem_addr[12:2]][15:8]  <= dmem_wdata[15:8];
        if (dmem_wen[2]) dmem[dmem_addr[12:2]][23:16] <= dmem_wdata[23:16];
        if (dmem_wen[3]) dmem[dmem_addr[12:2]][31:24] <= dmem_wdata[31:24];
    end

    // No assume()s on RVFI outputs — the checker framework tests them. If
    // the DUT reports a bad mem address / mask / next-PC, the solver finds it.

    core uut (
        .clock              (clock),
        .reset              (reset),
        .io_imemAddr        (imem_addr),
        .io_imemData        (imem_data),
        // riscv-formal models a zero-wait imem/dmem (the symbolic stream
        // is always available). Tying ready high keeps the formal SMT
        // tractable; modeling random ready=0 would explode the
        // search space without testing a property the framework checks.
        .io_imemReady       (1'b1),
        .io_dmemAddr        (dmem_addr),
        .io_dmemWData       (dmem_wdata),
        .io_dmemRData       (dmem[dmem_addr[12:2]]),  // combinational read
        .io_dmemWEn         (dmem_wen),
        .io_dmemREn         (dmem_ren),
        .io_dmemReady       (1'b1),
        // Channel 0 — low NRET slice of each RVFI bus.
        .io_rvfi_valid_0    (rvfi_valid    [0]),
        .io_rvfi_order_0    (rvfi_order    [63:0]),
        .io_rvfi_insn_0     (rvfi_insn     [31:0]),
        .io_rvfi_trap_0     (rvfi_trap     [0]),
        .io_rvfi_halt_0     (rvfi_halt     [0]),
        .io_rvfi_intr_0     (rvfi_intr     [0]),
        .io_rvfi_mode_0     (rvfi_mode     [1:0]),
        .io_rvfi_ixl_0      (rvfi_ixl      [1:0]),
        .io_rvfi_rs1_addr_0 (rvfi_rs1_addr [4:0]),
        .io_rvfi_rs1_rdata_0(rvfi_rs1_rdata[31:0]),
        .io_rvfi_rs2_addr_0 (rvfi_rs2_addr [4:0]),
        .io_rvfi_rs2_rdata_0(rvfi_rs2_rdata[31:0]),
        .io_rvfi_rd_addr_0  (rvfi_rd_addr  [4:0]),
        .io_rvfi_rd_wdata_0 (rvfi_rd_wdata [31:0]),
        .io_rvfi_pc_rdata_0 (rvfi_pc_rdata [31:0]),
        .io_rvfi_pc_wdata_0 (rvfi_pc_wdata [31:0]),
        .io_rvfi_mem_addr_0 (rvfi_mem_addr [31:0]),
        .io_rvfi_mem_rmask_0(rvfi_mem_rmask[3:0]),
        .io_rvfi_mem_wmask_0(rvfi_mem_wmask[3:0]),
        .io_rvfi_mem_rdata_0(rvfi_mem_rdata[31:0]),
        .io_rvfi_mem_wdata_0(rvfi_mem_wdata[31:0]),
        // Channel 1 — high NRET slice. riscv-formal packs higher channels
        // in higher bit ranges: rvfi_<field>[NRET*W-1:W] for ch 1.
        .io_rvfi_valid_1    (rvfi_valid    [1]),
        .io_rvfi_order_1    (rvfi_order    [127:64]),
        .io_rvfi_insn_1     (rvfi_insn     [63:32]),
        .io_rvfi_trap_1     (rvfi_trap     [1]),
        .io_rvfi_halt_1     (rvfi_halt     [1]),
        .io_rvfi_intr_1     (rvfi_intr     [1]),
        .io_rvfi_mode_1     (rvfi_mode     [3:2]),
        .io_rvfi_ixl_1      (rvfi_ixl      [3:2]),
        .io_rvfi_rs1_addr_1 (rvfi_rs1_addr [9:5]),
        .io_rvfi_rs1_rdata_1(rvfi_rs1_rdata[63:32]),
        .io_rvfi_rs2_addr_1 (rvfi_rs2_addr [9:5]),
        .io_rvfi_rs2_rdata_1(rvfi_rs2_rdata[63:32]),
        .io_rvfi_rd_addr_1  (rvfi_rd_addr  [9:5]),
        .io_rvfi_rd_wdata_1 (rvfi_rd_wdata [63:32]),
        .io_rvfi_pc_rdata_1 (rvfi_pc_rdata [63:32]),
        .io_rvfi_pc_wdata_1 (rvfi_pc_wdata [63:32]),
        .io_rvfi_mem_addr_1 (rvfi_mem_addr [63:32]),
        .io_rvfi_mem_rmask_1(rvfi_mem_rmask[7:4]),
        .io_rvfi_mem_wmask_1(rvfi_mem_wmask[7:4]),
        .io_rvfi_mem_rdata_1(rvfi_mem_rdata[63:32]),
        .io_rvfi_mem_wdata_1(rvfi_mem_wdata[63:32])
    );

endmodule
