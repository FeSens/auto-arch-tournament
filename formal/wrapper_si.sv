// riscv-formal wrapper for single-issue (`nret 1`) cores. Same shape and
// memory model as wrapper.sv, but instantiates `core` with only the
// channel-0 RVFI port set — no `_1` ports. The single-issue path produces
// only ch0 checks; checks_si.cfg sets `nret 1` so genchecks does not
// emit any `_ch1` tasks (no PREUNSAT-as-pass tally needed). Selected by
// the orchestrator when cores/<target>/core.yaml declares nret: 1.
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

    core uut (
        .clock              (clock),
        .reset              (reset),
        .io_imemAddr        (imem_addr),
        .io_imemData        (imem_data),
        .io_imemReady       (1'b1),
        .io_dmemAddr        (dmem_addr),
        .io_dmemWData       (dmem_wdata),
        .io_dmemRData       (dmem[dmem_addr[12:2]]),
        .io_dmemWEn         (dmem_wen),
        .io_dmemREn         (dmem_ren),
        .io_dmemReady       (1'b1),
        // Channel 0 — the only retirement channel. With nret=1 in
        // checks_si.cfg, every rvfi_* signal here is sized for a single
        // channel, so the core's `_0` ports connect directly without
        // slicing. No `_1` ports exist on the core's IO under nret=1.
        .io_rvfi_valid_0    (rvfi_valid),
        .io_rvfi_order_0    (rvfi_order),
        .io_rvfi_insn_0     (rvfi_insn),
        .io_rvfi_trap_0     (rvfi_trap),
        .io_rvfi_halt_0     (rvfi_halt),
        .io_rvfi_intr_0     (rvfi_intr),
        .io_rvfi_mode_0     (rvfi_mode),
        .io_rvfi_ixl_0      (rvfi_ixl),
        .io_rvfi_rs1_addr_0 (rvfi_rs1_addr),
        .io_rvfi_rs1_rdata_0(rvfi_rs1_rdata),
        .io_rvfi_rs2_addr_0 (rvfi_rs2_addr),
        .io_rvfi_rs2_rdata_0(rvfi_rs2_rdata),
        .io_rvfi_rd_addr_0  (rvfi_rd_addr),
        .io_rvfi_rd_wdata_0 (rvfi_rd_wdata),
        .io_rvfi_pc_rdata_0 (rvfi_pc_rdata),
        .io_rvfi_pc_wdata_0 (rvfi_pc_wdata),
        .io_rvfi_mem_addr_0 (rvfi_mem_addr),
        .io_rvfi_mem_rmask_0(rvfi_mem_rmask),
        .io_rvfi_mem_wmask_0(rvfi_mem_wmask),
        .io_rvfi_mem_rdata_0(rvfi_mem_rdata),
        .io_rvfi_mem_wdata_0(rvfi_mem_wdata)
    );

endmodule
