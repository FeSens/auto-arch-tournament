// VexRiscv GenFullNoMmuNoCache (README "full no cache": RV32IM, static branch
// prediction, full bypass, single-cycle barrel shifter, MUL/DIV, CSR, debug;
// published 2.30 CoreMark/MHz) in the V2 Gowin Fmax harness. Mirrors
// fpga/core_bench_si.sv and research/v2/reference_vexriscv/vex_bench.sv: same
// pins, LFSR instruction data, bench_stall_gen ready sequence, 2048-word dmem,
// LED = XOR of the memory-side outputs. IBusSimple and DBusSimple are answered
// one cycle after the command fires (dmem as synchronous block RAM; stores
// have no response); command ready follows the stall sequence.
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

  logic        i_cmd_valid, i_rsp_valid;
  logic [31:0] i_cmd_pc, i_rsp_inst;
  always_ff @(posedge clock or posedge reset)
    if (reset) begin i_rsp_valid <= 1'b0; i_rsp_inst <= 32'd0; end
    else begin
      i_rsp_valid <= i_cmd_valid && imem_ready;
      i_rsp_inst  <= lfsr;
    end

  logic        d_cmd_valid, d_cmd_wr, d_rsp_ready;
  logic [3:0]  d_cmd_mask;
  logic [31:0] d_cmd_addr, d_cmd_data, d_rsp_data;
  logic [1:0]  d_cmd_size;
  logic [31:0] dmem [0:2047];
  always_ff @(posedge clock) d_rsp_data <= dmem[d_cmd_addr[12:2]];
  always_ff @(posedge clock)
    if (d_cmd_valid && dmem_ready && d_cmd_wr) begin
      if (d_cmd_mask[0]) dmem[d_cmd_addr[12:2]][7:0]   <= d_cmd_data[7:0];
      if (d_cmd_mask[1]) dmem[d_cmd_addr[12:2]][15:8]  <= d_cmd_data[15:8];
      if (d_cmd_mask[2]) dmem[d_cmd_addr[12:2]][23:16] <= d_cmd_data[23:16];
      if (d_cmd_mask[3]) dmem[d_cmd_addr[12:2]][31:24] <= d_cmd_data[31:24];
    end
  always_ff @(posedge clock or posedge reset)
    if (reset) d_rsp_ready <= 1'b0;
    else       d_rsp_ready <= d_cmd_valid && dmem_ready && !d_cmd_wr;

  logic        dbg_cmd_ready, dbg_reset_out;
  logic [31:0] dbg_rsp_data;

  VexRiscv cpu (
    .clk                           (clock),
    .reset                         (reset),
    .debugReset                    (reset),
    .iBus_cmd_valid                (i_cmd_valid),
    .iBus_cmd_ready                (imem_ready),
    .iBus_cmd_payload_pc           (i_cmd_pc),
    .iBus_rsp_valid                (i_rsp_valid),
    .iBus_rsp_payload_error        (1'b0),
    .iBus_rsp_payload_inst         (i_rsp_inst),
    .dBus_cmd_valid                (d_cmd_valid),
    .dBus_cmd_ready                (dmem_ready),
    .dBus_cmd_payload_wr           (d_cmd_wr),
    .dBus_cmd_payload_mask         (d_cmd_mask),
    .dBus_cmd_payload_address      (d_cmd_addr),
    .dBus_cmd_payload_data         (d_cmd_data),
    .dBus_cmd_payload_size         (d_cmd_size),
    .dBus_rsp_ready                (d_rsp_ready),
    .dBus_rsp_error                (1'b0),
    .dBus_rsp_data                 (d_rsp_data),
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

  assign led = ^{i_cmd_valid, i_cmd_pc, d_cmd_valid, d_cmd_wr, d_cmd_mask, d_cmd_addr,
                 d_cmd_data, d_cmd_size, dbg_cmd_ready, dbg_rsp_data, dbg_reset_out};

endmodule
