// VexiiRiscv "rv32im branchPredict" (src/test/scala/vexiiriscv/scratchpad/
// Synt.scala: async register file, bypass from stage 0, relaxed branch and
// BTB, fetch fork at 1, BTB + GShare + RAS, no caches; published 2.99
// CoreMark/MHz, marked "too early" by its authors) in the V2 Gowin Fmax
// harness. Mirrors fpga/core_bench_si.sv: same pins, LFSR instruction data,
// bench_stall_gen ready sequence, 2048-word dmem, LED = XOR of the
// memory-side outputs. The cacheless fetch and LSU buses get one response per
// command (stores included), one cycle after the command fires, with the
// command's id echoed; dmem is synchronous block RAM.
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

  logic        f_cmd_valid, f_rsp_valid;
  logic [0:0]  f_cmd_id, f_rsp_id;
  logic [31:0] f_cmd_addr, f_rsp_word;
  always_ff @(posedge clock or posedge reset)
    if (reset) begin f_rsp_valid <= 1'b0; f_rsp_id <= 1'b0; f_rsp_word <= 32'd0; end
    else begin
      f_rsp_valid <= f_cmd_valid && imem_ready;
      f_rsp_id    <= f_cmd_id;
      f_rsp_word  <= lfsr;
    end

  logic        l_cmd_valid, l_cmd_write, l_cmd_io, l_cmd_from_hart, l_rsp_valid;
  logic [0:0]  l_cmd_id, l_rsp_id;
  logic [31:0] l_cmd_addr, l_cmd_data, l_rsp_data;
  logic [1:0]  l_cmd_size;
  logic [3:0]  l_cmd_mask;
  logic [15:0] l_cmd_uop;
  logic [31:0] dmem [0:2047];
  always_ff @(posedge clock) l_rsp_data <= dmem[l_cmd_addr[12:2]];
  always_ff @(posedge clock)
    if (l_cmd_valid && dmem_ready && l_cmd_write) begin
      if (l_cmd_mask[0]) dmem[l_cmd_addr[12:2]][7:0]   <= l_cmd_data[7:0];
      if (l_cmd_mask[1]) dmem[l_cmd_addr[12:2]][15:8]  <= l_cmd_data[15:8];
      if (l_cmd_mask[2]) dmem[l_cmd_addr[12:2]][23:16] <= l_cmd_data[23:16];
      if (l_cmd_mask[3]) dmem[l_cmd_addr[12:2]][31:24] <= l_cmd_data[31:24];
    end
  always_ff @(posedge clock or posedge reset)
    if (reset) begin l_rsp_valid <= 1'b0; l_rsp_id <= 1'b0; end
    else begin
      l_rsp_valid <= l_cmd_valid && dmem_ready;
      l_rsp_id    <= l_cmd_id;
    end

  VexiiRiscv cpu (
    .PrivilegedPlugin_logic_rdtime                     ({32'd0, lfsr}),
    .PrivilegedPlugin_logic_harts_0_int_m_timer        (lfsr[3]),
    .PrivilegedPlugin_logic_harts_0_int_m_software     (lfsr[11]),
    .PrivilegedPlugin_logic_harts_0_int_m_external     (lfsr[7]),
    .FetchCachelessPlugin_logic_bus_cmd_valid          (f_cmd_valid),
    .FetchCachelessPlugin_logic_bus_cmd_ready          (imem_ready),
    .FetchCachelessPlugin_logic_bus_cmd_payload_id     (f_cmd_id),
    .FetchCachelessPlugin_logic_bus_cmd_payload_address(f_cmd_addr),
    .FetchCachelessPlugin_logic_bus_rsp_valid          (f_rsp_valid),
    .FetchCachelessPlugin_logic_bus_rsp_payload_id     (f_rsp_id),
    .FetchCachelessPlugin_logic_bus_rsp_payload_error  (1'b0),
    .FetchCachelessPlugin_logic_bus_rsp_payload_word   (f_rsp_word),
    .LsuCachelessPlugin_logic_bus_cmd_valid            (l_cmd_valid),
    .LsuCachelessPlugin_logic_bus_cmd_ready            (dmem_ready),
    .LsuCachelessPlugin_logic_bus_cmd_payload_id       (l_cmd_id),
    .LsuCachelessPlugin_logic_bus_cmd_payload_write    (l_cmd_write),
    .LsuCachelessPlugin_logic_bus_cmd_payload_address  (l_cmd_addr),
    .LsuCachelessPlugin_logic_bus_cmd_payload_data     (l_cmd_data),
    .LsuCachelessPlugin_logic_bus_cmd_payload_size     (l_cmd_size),
    .LsuCachelessPlugin_logic_bus_cmd_payload_mask     (l_cmd_mask),
    .LsuCachelessPlugin_logic_bus_cmd_payload_io       (l_cmd_io),
    .LsuCachelessPlugin_logic_bus_cmd_payload_fromHart (l_cmd_from_hart),
    .LsuCachelessPlugin_logic_bus_cmd_payload_uopId    (l_cmd_uop),
    .LsuCachelessPlugin_logic_bus_rsp_valid            (l_rsp_valid),
    .LsuCachelessPlugin_logic_bus_rsp_payload_id       (l_rsp_id),
    .LsuCachelessPlugin_logic_bus_rsp_payload_error    (1'b0),
    .LsuCachelessPlugin_logic_bus_rsp_payload_data     (l_rsp_data),
    .clk                                               (clock),
    .reset                                             (reset)
  );

  assign led = ^{f_cmd_valid, f_cmd_id, f_cmd_addr, l_cmd_valid, l_cmd_id, l_cmd_write,
                 l_cmd_addr, l_cmd_data, l_cmd_size, l_cmd_mask, l_cmd_io, l_cmd_from_hart};

endmodule
