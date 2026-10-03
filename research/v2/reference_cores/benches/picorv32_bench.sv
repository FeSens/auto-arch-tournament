// PicoRV32 (rv32im: BARREL_SHIFTER, ENABLE_FAST_MUL, ENABLE_DIV) in the V2
// Gowin Fmax harness. Mirrors fpga/core_bench_si.sv: same pins, LFSR
// instruction data, bench_stall_gen ready sequence, 2048-word dmem, LED = XOR
// of the memory-side outputs. PicoRV32 has one valid/ready bus for both
// instruction and data; mem_instr selects the LFSR or the dmem block RAM.
// Responses come one cycle after the request (synchronous block RAM).
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

  logic        mem_valid, mem_instr, mem_ready, trap;
  logic [31:0] mem_addr, mem_wdata, mem_rdata;
  logic [3:0]  mem_wstrb;

  logic [31:0] dmem [0:2047];
  logic [31:0] d_rdata, i_rdata;
  logic        go, resp_instr;
  assign go = !mem_ready && (mem_instr ? imem_ready : dmem_ready);

  always_ff @(posedge clock) d_rdata <= dmem[mem_addr[12:2]];
  always_ff @(posedge clock)
    if (mem_valid && go && !mem_instr) begin
      if (mem_wstrb[0]) dmem[mem_addr[12:2]][7:0]   <= mem_wdata[7:0];
      if (mem_wstrb[1]) dmem[mem_addr[12:2]][15:8]  <= mem_wdata[15:8];
      if (mem_wstrb[2]) dmem[mem_addr[12:2]][23:16] <= mem_wdata[23:16];
      if (mem_wstrb[3]) dmem[mem_addr[12:2]][31:24] <= mem_wdata[31:24];
    end

  always_ff @(posedge clock or posedge reset)
    if (reset) begin mem_ready <= 1'b0; resp_instr <= 1'b0; i_rdata <= 32'd0; end
    else begin
      mem_ready  <= mem_valid && go;
      resp_instr <= mem_instr;
      i_rdata    <= lfsr;
    end
  assign mem_rdata = resp_instr ? i_rdata : d_rdata;

  picorv32 #(
    .BARREL_SHIFTER  (1),
    .ENABLE_MUL      (0),
    .ENABLE_FAST_MUL (1),
    .ENABLE_DIV      (1),
    .COMPRESSED_ISA  (0),
    .ENABLE_IRQ      (0)
  ) cpu (
    .clk          (clock),
    .resetn       (!reset),
    .trap         (trap),
    .mem_valid    (mem_valid),
    .mem_instr    (mem_instr),
    .mem_ready    (mem_ready),
    .mem_addr     (mem_addr),
    .mem_wdata    (mem_wdata),
    .mem_wstrb    (mem_wstrb),
    .mem_rdata    (mem_rdata),
    .mem_la_read  (),
    .mem_la_write (),
    .mem_la_addr  (),
    .mem_la_wdata (),
    .mem_la_wstrb (),
    .pcpi_valid   (),
    .pcpi_insn    (),
    .pcpi_rs1     (),
    .pcpi_rs2     (),
    .pcpi_wr      (1'b0),
    .pcpi_rd      (32'd0),
    .pcpi_wait    (1'b0),
    .pcpi_ready   (1'b0),
    .irq          (32'd0),
    .eoi          (),
    .trace_valid  (),
    .trace_data   ()
  );

  assign led = ^{mem_valid, mem_instr, mem_addr, mem_wdata, mem_wstrb, trap};

endmodule
