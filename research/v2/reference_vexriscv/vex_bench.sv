// VexRiscv "full max perf" (GenFullNoMmuMaxPerf) in the V2 Gowin Fmax harness.
// Mirrors fpga/core_bench_si.sv: same pins, same LFSR instruction source, same
// bench_stall_gen ready sequence, same 2048-word async-read dmem, LED = XOR of
// the memory-side outputs. VexRiscv's cached buses refill 32-byte lines as
// 8 beats; the interrupt and debug inputs come from LFSR bits so the debug
// module and CSR/interrupt logic of this config stay in the netlist.
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

  // iBus: one outstanding line refill, 8 beats of LFSR data.
  logic        i_cmd_valid, i_cmd_ready, i_rsp_valid;
  logic [31:0] i_cmd_addr;
  logic [2:0]  i_cmd_size;
  logic        ibusy;
  logic [2:0]  ibeat;
  assign i_cmd_ready = !ibusy && imem_ready;
  assign i_rsp_valid = ibusy && imem_ready;
  always_ff @(posedge clock or posedge reset)
    if (reset) begin ibusy <= 1'b0; ibeat <= 3'd0; end
    else if (i_cmd_valid && i_cmd_ready) begin ibusy <= 1'b1; ibeat <= 3'd0; end
    else if (i_rsp_valid) begin
      ibeat <= ibeat + 3'd1;
      if (ibeat == 3'd7) ibusy <= 1'b0;
    end

  // dBus: write-through single-beat stores; loads are 8-beat line refills
  // (size 5) or single-beat uncached reads.
  logic        d_cmd_valid, d_cmd_ready, d_cmd_wr, d_cmd_uncached, d_cmd_last;
  logic [31:0] d_cmd_addr, d_cmd_data;
  logic [3:0]  d_cmd_mask;
  logic [2:0]  d_cmd_size;
  logic        dbusy;
  logic [2:0]  dbeat, dlen;
  logic [31:0] dmem [0:2047];
  logic [10:0] ridx;
  logic        d_rsp_valid, d_rsp_last;
  logic [31:0] d_rsp_data;

  assign d_cmd_ready = !dbusy && dmem_ready;
  assign d_rsp_valid = dbusy && dmem_ready;
  assign d_rsp_last  = (dbeat == dlen);
  // Synchronous read of the next index = async read of the registered index
  // (the form Gowin maps to block RAM, like core_bench's registered address).
  logic [10:0] ridx_d;
  always_comb begin
    ridx_d = ridx;
    if (d_cmd_valid && d_cmd_ready && !d_cmd_wr)
      ridx_d = (d_cmd_size == 3'd5) ? {d_cmd_addr[12:5], 3'd0} : d_cmd_addr[12:2];
    else if (d_rsp_valid)
      ridx_d = {ridx[10:3], ridx[2:0] + 3'd1};
  end
  always_ff @(posedge clock) d_rsp_data <= dmem[ridx_d];

  always_ff @(posedge clock)
    if (d_cmd_valid && d_cmd_ready && d_cmd_wr) begin
      if (d_cmd_mask[0]) dmem[d_cmd_addr[12:2]][7:0]   <= d_cmd_data[7:0];
      if (d_cmd_mask[1]) dmem[d_cmd_addr[12:2]][15:8]  <= d_cmd_data[15:8];
      if (d_cmd_mask[2]) dmem[d_cmd_addr[12:2]][23:16] <= d_cmd_data[23:16];
      if (d_cmd_mask[3]) dmem[d_cmd_addr[12:2]][31:24] <= d_cmd_data[31:24];
    end

  always_ff @(posedge clock or posedge reset)
    if (reset) ridx <= 11'd0; else ridx <= ridx_d;

  always_ff @(posedge clock or posedge reset)
    if (reset) begin dbusy <= 1'b0; dbeat <= 3'd0; dlen <= 3'd0; end
    else if (d_cmd_valid && d_cmd_ready && !d_cmd_wr) begin
      dbusy <= 1'b1; dbeat <= 3'd0;
      dlen  <= (d_cmd_size == 3'd5) ? 3'd7 : 3'd0;
    end
    else if (d_rsp_valid) begin
      dbeat <= dbeat + 3'd1;
      if (d_rsp_last) dbusy <= 1'b0;
    end

  logic        dbg_cmd_ready, dbg_reset_out;
  logic [31:0] dbg_rsp_data;

  VexRiscv cpu (
    .clk                           (clock),
    .reset                         (reset),
    .debugReset                    (reset),
    .iBus_cmd_valid                (i_cmd_valid),
    .iBus_cmd_ready                (i_cmd_ready),
    .iBus_cmd_payload_address      (i_cmd_addr),
    .iBus_cmd_payload_size         (i_cmd_size),
    .iBus_rsp_valid                (i_rsp_valid),
    .iBus_rsp_payload_data         (lfsr),
    .iBus_rsp_payload_error        (1'b0),
    .dBus_cmd_valid                (d_cmd_valid),
    .dBus_cmd_ready                (d_cmd_ready),
    .dBus_cmd_payload_wr           (d_cmd_wr),
    .dBus_cmd_payload_uncached     (d_cmd_uncached),
    .dBus_cmd_payload_address      (d_cmd_addr),
    .dBus_cmd_payload_data         (d_cmd_data),
    .dBus_cmd_payload_mask         (d_cmd_mask),
    .dBus_cmd_payload_size         (d_cmd_size),
    .dBus_cmd_payload_last         (d_cmd_last),
    .dBus_rsp_valid                (d_rsp_valid),
    .dBus_rsp_payload_last         (d_rsp_last),
    .dBus_rsp_payload_data         (d_rsp_data),
    .dBus_rsp_payload_error        (1'b0),
    .timerInterrupt                (lfsr[3]),
    .externalInterrupt             (lfsr[7]),
    .softwareInterrupt             (lfsr[11]),
    .debug_bus_cmd_valid           (lfsr[13] & lfsr[17]),
    .debug_bus_cmd_ready           (dbg_cmd_ready),
    .debug_bus_cmd_payload_wr      (lfsr[19]),
    .debug_bus_cmd_payload_address ({lfsr[23:20], lfsr[31:28]}),
    .debug_bus_cmd_payload_data    ({lfsr[15:0], lfsr[31:16]}),
    .debug_bus_rsp_data            (dbg_rsp_data),
    .debug_resetOut                (dbg_reset_out)
  );

  assign led = ^{i_cmd_valid, i_cmd_addr, i_cmd_size,
                 d_cmd_valid, d_cmd_wr, d_cmd_uncached, d_cmd_addr, d_cmd_data,
                 d_cmd_mask, d_cmd_size, d_cmd_last, d_rsp_data,
                 dbg_cmd_ready, dbg_rsp_data, dbg_reset_out};

endmodule
