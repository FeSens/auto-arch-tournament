// Stage 2 adapter: Hazard3 (same parameters as benches/hazard3_bench.sv) on
// the ref_sim memory interface. Both ports are AHB-Lite: the address phase is
// registered, the memory access happens in the data phase, and the stall
// draw is the data phase's HREADY (so an unstalled access is address phase
// then one data-phase cycle, like synchronous memory).
module ref_top (
  input  logic        clock, reset,
  output logic [31:0] io_imemAddr, output logic io_imemReq,
  input  logic [31:0] io_imemData, input logic [31:0] io_imemData1, input logic io_imemReady,
  output logic [31:0] io_dmemAddr, output logic [31:0] io_dmemWData,
  output logic [3:0]  io_dmemWEn,  output logic io_dmemREn,
  input  logic [31:0] io_dmemRData, input logic io_dmemReady
);
  logic [31:0] i_haddr, i_hwdata, i_addr_q;
  logic        i_hwrite, i_hmastlock, i_hready, i_dphase;
  logic [1:0]  i_htrans;
  logic [2:0]  i_hsize, i_hburst;
  logic [3:0]  i_hprot;
  logic [7:0]  i_hmaster;
  assign i_hready    = i_dphase ? io_imemReady : 1'b1;
  assign io_imemReq  = i_dphase;
  assign io_imemAddr = i_addr_q;
  always_ff @(posedge clock)
    if (reset) begin i_dphase <= 1'b0; i_addr_q <= 32'd0; end
    else if (i_hready) begin i_dphase <= i_htrans[1]; i_addr_q <= i_haddr; end

  logic [31:0] d_haddr, d_hwdata, d_addr_q;
  logic        d_hwrite, d_hmastlock, d_hexcl, d_hready, d_dphase, d_write_q;
  logic [1:0]  d_htrans;
  logic [2:0]  d_hsize, d_hburst, d_size_q;
  logic [3:0]  d_hprot, d_be;
  logic [7:0]  d_hmaster;
  assign d_hready = d_dphase ? io_dmemReady : 1'b1;
  always_ff @(posedge clock)
    if (reset) begin d_dphase <= 1'b0; d_write_q <= 1'b0; d_addr_q <= 32'd0; d_size_q <= 3'd0; end
    else if (d_hready) begin
      d_dphase <= d_htrans[1]; d_write_q <= d_hwrite; d_addr_q <= d_haddr; d_size_q <= d_hsize;
    end
  always_comb
    case (d_size_q[1:0])
      2'd0:    d_be = 4'b0001 << d_addr_q[1:0];
      2'd1:    d_be = d_addr_q[1] ? 4'b1100 : 4'b0011;
      default: d_be = 4'b1111;
    endcase
  assign io_dmemAddr  = d_addr_q;
  assign io_dmemWData = d_hwdata;
  assign io_dmemWEn   = (d_dphase && d_write_q) ? d_be : 4'b0;
  assign io_dmemREn   = d_dphase && !d_write_q;

  logic pwrup_req, unblock_out;
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
    .clk (clock), .clk_always_on (clock), .rst_n (!reset),
    .pwrup_req (pwrup_req), .pwrup_ack (pwrup_req), .clk_en (), .unblock_out (unblock_out), .unblock_in (unblock_out),
    .i_haddr (i_haddr), .i_hwrite (i_hwrite), .i_htrans (i_htrans), .i_hsize (i_hsize), .i_hburst (i_hburst),
    .i_hprot (i_hprot), .i_hmastlock (i_hmastlock), .i_hmaster (i_hmaster), .i_hready (i_hready),
    .i_hresp (1'b0), .i_hwdata (i_hwdata), .i_hrdata (io_imemData),
    .d_haddr (d_haddr), .d_hwrite (d_hwrite), .d_htrans (d_htrans), .d_hsize (d_hsize), .d_hburst (d_hburst),
    .d_hprot (d_hprot), .d_hmastlock (d_hmastlock), .d_hmaster (d_hmaster), .d_hexcl (d_hexcl),
    .d_hready (d_hready), .d_hresp (1'b0), .d_hexokay (1'b1), .d_hwdata (d_hwdata), .d_hrdata (io_dmemRData),
    .fence_i_vld (), .fence_d_vld (), .fence_rdy (1'b1),
    .dbg_req_halt (1'b0), .dbg_req_halt_on_reset (1'b0), .dbg_req_resume (1'b0), .dbg_halted (), .dbg_running (),
    .dbg_data0_rdata (32'd0), .dbg_data0_wdata (), .dbg_data0_wen (),
    .dbg_instr_data (32'd0), .dbg_instr_data_vld (1'b0), .dbg_instr_data_rdy (),
    .dbg_instr_caught_exception (), .dbg_instr_caught_ebreak (),
    .dbg_sbus_addr (32'd0), .dbg_sbus_write (1'b0), .dbg_sbus_size (2'd0), .dbg_sbus_vld (1'b0),
    .dbg_sbus_rdy (), .dbg_sbus_err (), .dbg_sbus_wdata (32'd0), .dbg_sbus_rdata (),
    .mhartid_val (32'd0), .eco_version (4'd0), .irq (1'b0), .soft_irq (1'b0), .timer_irq (1'b0)
  );
endmodule
