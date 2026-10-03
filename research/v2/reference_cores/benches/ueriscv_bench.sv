// ultraembedded riscv (riscv_core, default rv32im config) in the V2 Gowin Fmax harness. Mirrors fpga/core_bench_si.sv:
// same pins, LFSR instruction data, bench_stall_gen ready sequence, 2048-word
// dmem, LED = XOR of the memory-side outputs. The buses are answered the way
// the core's own TCM answers them (top_tcm_axi/tcm_mem.v): accept, then
// valid/ack one cycle later from synchronous block RAM; accept follows the
// stall sequence. Core parameters are the upstream defaults (MULDIV, load and multiply
// bypass, no MMU, no supervisor mode) with the flip-flop register file.
module core_bench (
  input  logic clock,
  input  logic reset,
  output logic led
);

  logic [31:0] lfsr, lfsr2;
  always_ff @(posedge clock or posedge reset)
    if (reset) begin lfsr <= 32'h1; lfsr2 <= 32'hACE1; end
    else begin
      lfsr  <= {lfsr[30:0],  lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      lfsr2 <= {lfsr2[30:0], lfsr2[31] ^ lfsr2[21] ^ lfsr2[1] ^ lfsr2[0]};
    end

  logic imem_ready, dmem_ready;
  bench_stall_gen stall_gen (
    .clock      (clock),
    .reset      (reset),
    .imem_ready (imem_ready),
    .dmem_ready (dmem_ready)
  );

  // Instruction side.
  logic        i_rd, i_flush, i_inval, i_valid_q;
  logic [31:0] i_pc;
  logic [31:0]  i_inst_q;
  always_ff @(posedge clock or posedge reset)
    if (reset) begin i_valid_q <= 1'b0; i_inst_q <= '0; end
    else begin
      i_valid_q <= i_rd && imem_ready;
      i_inst_q  <= lfsr;
    end

  // Data side.
  logic [31:0] d_addr, d_wdata, d_rdata;
  logic        d_rd, d_cacheable, d_inval, d_wb, d_flush;
  logic [3:0]  d_wr;
  logic [10:0] d_tag, d_tag_q;
  logic        d_ack_q, d_req;
  logic [31:0] dmem [0:2047];
  assign d_req = d_rd || (d_wr != 4'b0) || d_flush || d_inval || d_wb;
  always_ff @(posedge clock) d_rdata <= dmem[d_addr[12:2]];
  always_ff @(posedge clock)
    if (dmem_ready) begin
      if (d_wr[0]) dmem[d_addr[12:2]][7:0]   <= d_wdata[7:0];
      if (d_wr[1]) dmem[d_addr[12:2]][15:8]  <= d_wdata[15:8];
      if (d_wr[2]) dmem[d_addr[12:2]][23:16] <= d_wdata[23:16];
      if (d_wr[3]) dmem[d_addr[12:2]][31:24] <= d_wdata[31:24];
    end
  always_ff @(posedge clock or posedge reset)
    if (reset) begin d_ack_q <= 1'b0; d_tag_q <= 11'd0; end
    else begin
      d_ack_q <= d_req && dmem_ready;
      if (d_req && dmem_ready) d_tag_q <= d_tag;
    end

  riscv_core #(
    .SUPPORT_MULDIV         (1),
    .SUPPORT_SUPER          (0),
    .SUPPORT_MMU            (0),
    .SUPPORT_LOAD_BYPASS    (1),
    .SUPPORT_MUL_BYPASS     (1),
    .SUPPORT_REGFILE_XILINX (0),
    .EXTRA_DECODE_STAGE     (0)
  ) cpu (
    .clk_i              (clock),
    .rst_i              (reset),
    .mem_d_data_rd_i    (d_rdata),
    .mem_d_accept_i     (dmem_ready),
    .mem_d_ack_i        (d_ack_q),
    .mem_d_error_i      (1'b0),
    .mem_d_resp_tag_i   (d_tag_q),
    .mem_i_accept_i     (imem_ready),
    .mem_i_valid_i      (i_valid_q),
    .mem_i_error_i      (1'b0),
    .mem_i_inst_i       (i_inst_q),
    .intr_i             (lfsr[7]),
    .reset_vector_i     (32'h0),
    .cpu_id_i           (32'h0),
    .mem_d_addr_o       (d_addr),
    .mem_d_data_wr_o    (d_wdata),
    .mem_d_rd_o         (d_rd),
    .mem_d_wr_o         (d_wr),
    .mem_d_cacheable_o  (d_cacheable),
    .mem_d_req_tag_o    (d_tag),
    .mem_d_invalidate_o (d_inval),
    .mem_d_writeback_o  (d_wb),
    .mem_d_flush_o      (d_flush),
    .mem_i_rd_o         (i_rd),
    .mem_i_flush_o      (i_flush),
    .mem_i_invalidate_o (i_inval),
    .mem_i_pc_o         (i_pc)
  );

  assign led = ^{i_rd, i_flush, i_inval, i_pc, d_addr, d_wdata, d_rd, d_wr,
                 d_cacheable, d_tag, d_inval, d_wb, d_flush};

endmodule
