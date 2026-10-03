// NEORV32 CPU (rv32im, fast multiplier and barrel shifter, no caches) in the
// V2 Gowin Fmax harness, through the flat-port VHDL shim neorv32_cpu_flat.vhd.
// Mirrors fpga/core_bench_si.sv: same pins, LFSR instruction data,
// bench_stall_gen ready sequence, 2048-word dmem, LED = XOR of the
// memory-side outputs. NEORV32's bus is a single-shot request strobe with the
// request held stable until a single-shot ACK; each port answers once the
// stall sequence allows, ACK one cycle later, dmem as synchronous block RAM.
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

  logic [31:0] i_addr, i_data;
  logic [4:0]  i_meta;
  logic        i_stb, i_pend, i_go, i_ack;
  assign i_go = (i_stb || i_pend) && imem_ready;
  always_ff @(posedge clock or posedge reset)
    if (reset) begin i_pend <= 1'b0; i_ack <= 1'b0; i_data <= 32'd0; end
    else begin
      i_pend <= (i_stb || i_pend) && !imem_ready;
      i_ack  <= i_go;
      i_data <= lfsr;
    end

  logic [31:0] d_addr, d_wdata, d_rdata;
  logic [3:0]  d_ben;
  logic [4:0]  d_meta;
  logic        d_stb, d_rw, d_pend, d_go, d_ack;
  logic [31:0] dmem [0:2047];
  assign d_go = (d_stb || d_pend) && dmem_ready;
  always_ff @(posedge clock) d_rdata <= dmem[d_addr[12:2]];
  always_ff @(posedge clock)
    if (d_go && d_rw) begin
      if (d_ben[0]) dmem[d_addr[12:2]][7:0]   <= d_wdata[7:0];
      if (d_ben[1]) dmem[d_addr[12:2]][15:8]  <= d_wdata[15:8];
      if (d_ben[2]) dmem[d_addr[12:2]][23:16] <= d_wdata[23:16];
      if (d_ben[3]) dmem[d_addr[12:2]][31:24] <= d_wdata[31:24];
    end
  always_ff @(posedge clock or posedge reset)
    if (reset) begin d_pend <= 1'b0; d_ack <= 1'b0; end
    else begin
      d_pend <= (d_stb || d_pend) && !dmem_ready;
      d_ack  <= d_go;
    end

  logic sleep, ifence, dfence;

  neorv32_cpu_flat cpu (
    .clk_i     (clock),
    .rstn_i    (!reset),
    .irq_i     ({lfsr[3], lfsr[7], lfsr[11]}),
    .sleep_o   (sleep),
    .ifence_o  (ifence),
    .dfence_o  (dfence),
    .i_addr_o  (i_addr),
    .i_stb_o   (i_stb),
    .i_meta_o  (i_meta),
    .i_ack_i   (i_ack),
    .i_data_i  (i_data),
    .d_addr_o  (d_addr),
    .d_wdata_o (d_wdata),
    .d_ben_o   (d_ben),
    .d_stb_o   (d_stb),
    .d_rw_o    (d_rw),
    .d_meta_o  (d_meta),
    .d_ack_i   (d_ack),
    .d_data_i  (d_rdata)
  );

  assign led = ^{i_addr, i_stb, i_meta, d_addr, d_wdata, d_ben, d_stb, d_rw, d_meta,
                 sleep, ifence, dfence};

endmodule
