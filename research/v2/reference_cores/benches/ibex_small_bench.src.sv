// Ibex "small" config (lowRISC/ibex e4bcf749, the newest mainline commit with
// no CHERIoT RTL) in the V2 Gowin Fmax harness. Mirrors fpga/core_bench_si.sv:
// same pins, LFSR instruction data, bench_stall_gen ready sequence, 2048-word
// dmem, LED = XOR of the memory-side outputs. Both buses are Ibex's
// req/gnt/rvalid protocol: GNT follows the stall sequence and RVALID comes one
// cycle after the grant, with dmem as synchronous block RAM.
//
// Parameters are ibex_configs.yaml "small" except RegFile = RegFileFPGA
// (Ibex's FPGA register file; same timing as RegFileFF in the pipeline).
// Converted to Verilog with sv2v (SYNTHESIS defined, as in syn/syn_yosys.sh);
// prim_clock_gating is a pass-through, as in Ibex's FPGA examples.
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

  logic        instr_req, instr_rvalid;
  logic [31:0] instr_addr, instr_rdata;
  always_ff @(posedge clock or posedge reset)
    if (reset) begin instr_rvalid <= 1'b0; instr_rdata <= 32'd0; end
    else begin
      instr_rvalid <= instr_req && imem_ready;
      instr_rdata  <= lfsr;
    end

  logic        data_req, data_we, data_rvalid;
  logic [3:0]  data_be;
  logic [31:0] data_addr, data_wdata, data_rdata;
  logic [6:0]  data_wdata_intg;
  logic [31:0] dmem [0:2047];
  always_ff @(posedge clock) data_rdata <= dmem[data_addr[12:2]];
  always_ff @(posedge clock)
    if (data_req && dmem_ready && data_we) begin
      if (data_be[0]) dmem[data_addr[12:2]][7:0]   <= data_wdata[7:0];
      if (data_be[1]) dmem[data_addr[12:2]][15:8]  <= data_wdata[15:8];
      if (data_be[2]) dmem[data_addr[12:2]][23:16] <= data_wdata[23:16];
      if (data_be[3]) dmem[data_addr[12:2]][31:24] <= data_wdata[31:24];
    end
  always_ff @(posedge clock or posedge reset)
    if (reset) data_rvalid <= 1'b0;
    else       data_rvalid <= data_req && dmem_ready;

  logic alert_minor, alert_major_int, alert_major_bus, core_sleep, double_fault;

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
    .instr_gnt_i            (imem_ready),
    .instr_rvalid_i         (instr_rvalid),
    .instr_addr_o           (instr_addr),
    .instr_rdata_i          (instr_rdata),
    .instr_rdata_intg_i     (7'd0),
    .instr_err_i            (1'b0),
    .data_req_o             (data_req),
    .data_gnt_i             (dmem_ready),
    .data_rvalid_i          (data_rvalid),
    .data_we_o              (data_we),
    .data_be_o              (data_be),
    .data_addr_o            (data_addr),
    .data_wdata_o           (data_wdata),
    .data_wdata_intg_o      (data_wdata_intg),
    .data_rdata_i           (data_rdata),
    .data_rdata_intg_i      (7'd0),
    .data_err_i             (1'b0),
    .irq_software_i         (lfsr[11]),
    .irq_timer_i            (lfsr[3]),
    .irq_external_i         (lfsr[7]),
    .irq_fast_i             (15'd0),
    .irq_nm_i               (1'b0),
    .scramble_key_valid_i   (1'b0),
    .scramble_key_i         ('0),
    .scramble_nonce_i       ('0),
    .scramble_req_o         (),
    .debug_req_i            (lfsr[13] & lfsr[17]),
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

  assign led = ^{instr_req, instr_addr, data_req, data_we, data_be, data_addr,
                 data_wdata, core_sleep, double_fault};

endmodule
