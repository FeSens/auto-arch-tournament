// Stage 2 adapter: Ibex "small" (same parameters as benches/ibex_small_bench.src.sv)
// on the ref_sim memory interface: GNT is the stall draw, RVALID and the read
// data come one cycle after the grant. Ibex boots at boot_addr + 0x80, so
// ref_sim runs it with --reset-pc 80 (one "jalr x0, 0(x0)" before the timed
// window). Converted to Verilog with sim/ibex_sim_sv2v.sh.
module ref_top (
  input  logic        clock, reset,
  output logic [31:0] io_imemAddr, output logic io_imemReq,
  input  logic [31:0] io_imemData, input logic [31:0] io_imemData1, input logic io_imemReady,
  output logic [31:0] io_dmemAddr, output logic [31:0] io_dmemWData,
  output logic [3:0]  io_dmemWEn,  output logic io_dmemREn,
  input  logic [31:0] io_dmemRData, input logic io_dmemReady
);
  logic        instr_req, instr_rvalid, data_req, data_we, data_rvalid;
  logic [31:0] instr_addr, instr_rdata, data_addr, data_wdata, data_rdata;
  logic [3:0]  data_be;
  logic [6:0]  data_wdata_intg;
  logic        alert_minor, alert_major_int, alert_major_bus, core_sleep, double_fault;
  assign io_imemReq   = instr_req;
  assign io_imemAddr  = instr_addr;
  assign io_dmemAddr  = data_addr;
  assign io_dmemWData = data_wdata;
  assign io_dmemWEn   = (data_req && data_we) ? data_be : 4'b0;
  assign io_dmemREn   = data_req && !data_we;
  always_ff @(posedge clock)
    if (reset) begin instr_rvalid <= 1'b0; data_rvalid <= 1'b0; end
    else begin
      instr_rvalid <= instr_req && io_imemReady;
      if (instr_req && io_imemReady) instr_rdata <= io_imemData;
      data_rvalid <= data_req && io_dmemReady;
      if (data_req && io_dmemReady) data_rdata <= io_dmemRData;
    end

  ibex_top #(
    .RV32E           (1'b0),
    .RV32M           (ibex_pkg::RV32MFast),
    .RV32B           (ibex_pkg::RV32BNone),
    .RV32ZC          (ibex_pkg::RV32Zca),
    .RegFile         (ibex_pkg::RegFileFPGA),
    .BranchTargetALU (1'b0),
    .WritebackStage  (1'b0),
    .ICache          (1'b0),
    .ICacheECC       (1'b0),
    .BranchPredictor (1'b0),
    .DbgTriggerEn    (1'b0),
    .SecureIbex      (1'b0),
    .PMPEnable       (1'b0),
    .MHPMCounterNum  (0)
  ) cpu (
    .clk_i                  (clock),
    .rst_ni                 (!reset),
    .test_en_i              (1'b0),
    .ram_cfg_icache_tag_i   ('0),
    .ram_cfg_icache_tag_o   (),
    .ram_cfg_icache_data_i  ('0),
    .ram_cfg_icache_data_o  (),
    .hart_id_i              (32'd0),
    .boot_addr_i            (32'd0),
    .instr_req_o            (instr_req),
    .instr_gnt_i            (io_imemReady),
    .instr_rvalid_i         (instr_rvalid),
    .instr_addr_o           (instr_addr),
    .instr_rdata_i          (instr_rdata),
    .instr_rdata_intg_i     (7'd0),
    .instr_err_i            (1'b0),
    .data_req_o             (data_req),
    .data_gnt_i             (io_dmemReady),
    .data_rvalid_i          (data_rvalid),
    .data_we_o              (data_we),
    .data_be_o              (data_be),
    .data_addr_o            (data_addr),
    .data_wdata_o           (data_wdata),
    .data_wdata_intg_o      (data_wdata_intg),
    .data_rdata_i           (data_rdata),
    .data_rdata_intg_i      (7'd0),
    .data_err_i             (1'b0),
    .irq_software_i         (1'b0),
    .irq_timer_i            (1'b0),
    .irq_external_i         (1'b0),
    .irq_fast_i             (15'd0),
    .irq_nm_i               (1'b0),
    .scramble_key_valid_i   (1'b0),
    .scramble_key_i         ('0),
    .scramble_nonce_i       ('0),
    .scramble_req_o         (),
    .debug_req_i            (1'b0),
    .crash_dump_o           (),
    .double_fault_seen_o    (double_fault),
    .fetch_enable_i         (ibex_pkg::IbexMuBiOn),
    .mcounteren_writable_i  (ibex_pkg::IbexMuBiOn),
    .alert_minor_o          (alert_minor),
    .alert_major_internal_o (alert_major_int),
    .alert_major_bus_o      (alert_major_bus),
    .core_sleep_o           (core_sleep),
    .scan_rst_ni            (1'b1),
    .lockstep_cmp_en_o      (),
    .data_req_shadow_o      (),
    .data_we_shadow_o       (),
    .data_be_shadow_o       (),
    .data_addr_shadow_o     (),
    .data_wdata_shadow_o    (),
    .data_wdata_intg_shadow_o (),
    .instr_req_shadow_o     (),
    .instr_addr_shadow_o    ()
  );

endmodule
