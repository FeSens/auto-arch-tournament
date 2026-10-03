// Hazard3 (hazard3_cpu_2port, rv32im build of its performance options) in the
// V2 Gowin Fmax harness. Mirrors fpga/core_bench_si.sv: same pins, LFSR
// instruction data, bench_stall_gen ready sequence, 2048-word dmem, LED = XOR
// of the memory-side outputs. Both ports are AHB-Lite; each slave answers in
// the data phase with HREADY from the stall sequence, and dmem is synchronous
// block RAM read at the end of the address phase.
//
// ISA is cut to the bench's RV32IM (no A, C, Zb*, Zcb, Zcmp, debug, PMP,
// U mode, counters); the performance options match the RP2350-like
// tb_common config_default.vh: MUL_FAST, MUL_FASTER, MULH_FAST,
// MULDIV_UNROLL 2, FAST_BRANCHCMP, BRANCH_PREDICTOR, full bypass.
// RESET_REGFILE 0 as recommended for FPGA.
module core_bench (
  input  logic clock,
  input  logic reset,
  output logic led
);

  logic [31:0] lfsr;
  always_ff @(posedge clock or posedge reset)
    if (reset) lfsr <= 32'h1;
    else       lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

  logic imem_ready, dmem_ready;
  bench_stall_gen stall_gen (
    .clock      (clock),
    .reset      (reset),
    .imem_ready (imem_ready),
    .dmem_ready (dmem_ready)
  );

  // Instruction port.
  logic [31:0] i_haddr, i_hwdata;
  logic        i_hwrite, i_hmastlock, i_hready, i_dphase;
  logic [1:0]  i_htrans;
  logic [2:0]  i_hsize, i_hburst;
  logic [3:0]  i_hprot;
  logic [7:0]  i_hmaster;
  assign i_hready = i_dphase ? imem_ready : 1'b1;
  always_ff @(posedge clock or posedge reset)
    if (reset) i_dphase <= 1'b0;
    else if (i_hready) i_dphase <= i_htrans[1];

  // Load/store port.
  logic [31:0] d_haddr, d_hwdata, d_hrdata, d_addr_q;
  logic        d_hwrite, d_hmastlock, d_hexcl, d_hready, d_dphase, d_write_q;
  logic [1:0]  d_htrans;
  logic [2:0]  d_hsize, d_hburst, d_size_q;
  logic [3:0]  d_hprot, d_be;
  logic [7:0]  d_hmaster;
  logic [31:0] dmem [0:2047];
  assign d_hready = d_dphase ? dmem_ready : 1'b1;
  always_ff @(posedge clock or posedge reset)
    if (reset) begin
      d_dphase <= 1'b0; d_write_q <= 1'b0; d_addr_q <= 32'd0; d_size_q <= 3'd0;
    end else if (d_hready) begin
      d_dphase  <= d_htrans[1];
      d_write_q <= d_hwrite;
      d_addr_q  <= d_haddr;
      d_size_q  <= d_hsize;
    end
  always_comb
    case (d_size_q[1:0])
      2'd0:    d_be = 4'b0001 << d_addr_q[1:0];
      2'd1:    d_be = d_addr_q[1] ? 4'b1100 : 4'b0011;
      default: d_be = 4'b1111;
    endcase
  always_ff @(posedge clock)
    if (d_hready) d_hrdata <= dmem[d_haddr[12:2]];
  always_ff @(posedge clock)
    if (d_dphase && d_write_q && dmem_ready) begin
      if (d_be[0]) dmem[d_addr_q[12:2]][7:0]   <= d_hwdata[7:0];
      if (d_be[1]) dmem[d_addr_q[12:2]][15:8]  <= d_hwdata[15:8];
      if (d_be[2]) dmem[d_addr_q[12:2]][23:16] <= d_hwdata[23:16];
      if (d_be[3]) dmem[d_addr_q[12:2]][31:24] <= d_hwdata[31:24];
    end

  logic pwrup_req, clk_en, unblock_out, fence_i_vld, fence_d_vld;
  logic dbg_halted, dbg_running, dbg_data0_wen, dbg_instr_data_rdy;
  logic dbg_instr_caught_exception, dbg_instr_caught_ebreak, dbg_sbus_rdy, dbg_sbus_err;
  logic [31:0] dbg_data0_wdata, dbg_sbus_rdata;

  hazard3_cpu_2port #(
    .RESET_VECTOR        (32'h0),
    .MTVEC_INIT          (32'h0),
    .EXTENSION_A         (0),
    .EXTENSION_C         (0),
    .EXTENSION_E         (0),
    .EXTENSION_M         (1),
    .EXTENSION_ZBA       (0),
    .EXTENSION_ZBB       (0),
    .EXTENSION_ZBC       (0),
    .EXTENSION_ZBKB      (0),
    .EXTENSION_ZBKX      (0),
    .EXTENSION_ZBS       (0),
    .EXTENSION_ZCB       (0),
    .EXTENSION_ZCLSD     (0),
    .EXTENSION_ZCMP      (0),
    .EXTENSION_ZIFENCEI  (0),
    .EXTENSION_ZILSD     (0),
    .EXTENSION_XH3BEXTM  (0),
    .EXTENSION_XH3IRQ    (0),
    .EXTENSION_XH3PMPM   (0),
    .EXTENSION_XH3POWER  (0),
    .CSR_M_MANDATORY     (1),
    .CSR_M_TRAP          (1),
    .CSR_COUNTER         (0),
    .U_MODE              (0),
    .PMP_REGIONS         (0),
    .DEBUG_SUPPORT       (0),
    .BREAKPOINT_TRIGGERS (0),
    .NUM_IRQS            (1),
    .IRQ_PRIORITY_BITS   (0),
    .REDUCED_BYPASS      (0),
    .MULDIV_UNROLL       (2),
    .MUL_FAST            (1),
    .MUL_FASTER          (1),
    .MULH_FAST           (1),
    .FAST_BRANCHCMP      (1),
    .RESET_REGFILE       (0),
    .BRANCH_PREDICTOR    (1)
  ) cpu (
    .clk                        (clock),
    .clk_always_on              (clock),
    .rst_n                      (!reset),
    .pwrup_req                  (pwrup_req),
    .pwrup_ack                  (pwrup_req),
    .clk_en                     (clk_en),
    .unblock_out                (unblock_out),
    .unblock_in                 (unblock_out),
    .i_haddr                    (i_haddr),
    .i_hwrite                   (i_hwrite),
    .i_htrans                   (i_htrans),
    .i_hsize                    (i_hsize),
    .i_hburst                   (i_hburst),
    .i_hprot                    (i_hprot),
    .i_hmastlock                (i_hmastlock),
    .i_hmaster                  (i_hmaster),
    .i_hready                   (i_hready),
    .i_hresp                    (1'b0),
    .i_hwdata                   (i_hwdata),
    .i_hrdata                   (lfsr),
    .d_haddr                    (d_haddr),
    .d_hwrite                   (d_hwrite),
    .d_htrans                   (d_htrans),
    .d_hsize                    (d_hsize),
    .d_hburst                   (d_hburst),
    .d_hprot                    (d_hprot),
    .d_hmastlock                (d_hmastlock),
    .d_hmaster                  (d_hmaster),
    .d_hexcl                    (d_hexcl),
    .d_hready                   (d_hready),
    .d_hresp                    (1'b0),
    .d_hexokay                  (1'b1),
    .d_hwdata                   (d_hwdata),
    .d_hrdata                   (d_hrdata),
    .fence_i_vld                (fence_i_vld),
    .fence_d_vld                (fence_d_vld),
    .fence_rdy                  (1'b1),
    .dbg_req_halt               (1'b0),
    .dbg_req_halt_on_reset      (1'b0),
    .dbg_req_resume             (1'b0),
    .dbg_halted                 (dbg_halted),
    .dbg_running                (dbg_running),
    .dbg_data0_rdata            (32'd0),
    .dbg_data0_wdata            (dbg_data0_wdata),
    .dbg_data0_wen              (dbg_data0_wen),
    .dbg_instr_data             (32'd0),
    .dbg_instr_data_vld         (1'b0),
    .dbg_instr_data_rdy         (dbg_instr_data_rdy),
    .dbg_instr_caught_exception (dbg_instr_caught_exception),
    .dbg_instr_caught_ebreak    (dbg_instr_caught_ebreak),
    .dbg_sbus_addr              (32'd0),
    .dbg_sbus_write             (1'b0),
    .dbg_sbus_size              (2'd0),
    .dbg_sbus_vld               (1'b0),
    .dbg_sbus_rdy               (dbg_sbus_rdy),
    .dbg_sbus_err               (dbg_sbus_err),
    .dbg_sbus_wdata             (32'd0),
    .dbg_sbus_rdata             (dbg_sbus_rdata),
    .mhartid_val                (32'd0),
    .eco_version                (4'd0),
    .irq                        (lfsr[7]),
    .soft_irq                   (lfsr[11]),
    .timer_irq                  (lfsr[3])
  );

  assign led = ^{i_haddr, i_hwrite, i_htrans, i_hsize, d_haddr, d_hwrite, d_htrans,
                 d_hsize, d_hwdata, fence_i_vld, fence_d_vld};

endmodule
