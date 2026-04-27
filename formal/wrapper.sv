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
        .io_rvfi_valid      (rvfi_valid),
        .io_rvfi_order      (rvfi_order),
        .io_rvfi_insn       (rvfi_insn),
        .io_rvfi_trap       (rvfi_trap),
        .io_rvfi_halt       (rvfi_halt),
        .io_rvfi_intr       (rvfi_intr),
        .io_rvfi_mode       (rvfi_mode),
        .io_rvfi_ixl        (rvfi_ixl),
        .io_rvfi_rs1_addr   (rvfi_rs1_addr),
        .io_rvfi_rs1_rdata  (rvfi_rs1_rdata),
        .io_rvfi_rs2_addr   (rvfi_rs2_addr),
        .io_rvfi_rs2_rdata  (rvfi_rs2_rdata),
        .io_rvfi_rd_addr    (rvfi_rd_addr),
        .io_rvfi_rd_wdata   (rvfi_rd_wdata),
        .io_rvfi_pc_rdata   (rvfi_pc_rdata),
        .io_rvfi_pc_wdata   (rvfi_pc_wdata),
        .io_rvfi_mem_addr   (rvfi_mem_addr),
        .io_rvfi_mem_rmask  (rvfi_mem_rmask),
        .io_rvfi_mem_rdata  (rvfi_mem_rdata),
        .io_rvfi_mem_wmask  (rvfi_mem_wmask),
        .io_rvfi_mem_wdata  (rvfi_mem_wdata)
    );

endmodule
