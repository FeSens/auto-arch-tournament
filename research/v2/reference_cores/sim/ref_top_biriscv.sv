// Stage 2 adapter: biRISC-V (same parameters as benches/biriscv_bench.sv) on the
// ref_sim memory interface, answered like the core's own TCM: accept when
// ready, valid/ack one cycle later.
// 64-bit fetch: the 8-byte-aligned pair of words (io_imemData1 is addr+4).
module ref_top (
  input  logic        clock, reset,
  output logic [31:0] io_imemAddr, output logic io_imemReq,
  input  logic [31:0] io_imemData, input logic [31:0] io_imemData1, input logic io_imemReady,
  output logic [31:0] io_dmemAddr, output logic [31:0] io_dmemWData,
  output logic [3:0]  io_dmemWEn,  output logic io_dmemREn,
  input  logic [31:0] io_dmemRData, input logic io_dmemReady
);
  logic        i_rd, i_flush, i_inval, i_valid_q;
  logic [31:0] i_pc;
  logic [63:0]  i_inst_q;
  assign io_imemReq  = i_rd;
  assign io_imemAddr = {i_pc[31:3], 3'b000};
  always_ff @(posedge clock)
    if (reset) begin i_valid_q <= 1'b0; i_inst_q <= '0; end
    else begin
      i_valid_q <= i_rd && io_imemReady;
      if (i_rd && io_imemReady) i_inst_q <= {io_imemData1, io_imemData};
    end

  logic [31:0] d_addr, d_wdata, d_rdata_q;
  logic        d_rd, d_cacheable, d_inval, d_wb, d_flush, d_req, d_ack_q;
  logic [3:0]  d_wr;
  logic [10:0] d_tag, d_tag_q;
  assign d_req = d_rd || (d_wr != 4'b0) || d_flush || d_inval || d_wb;
  assign io_dmemAddr  = d_addr;
  assign io_dmemWData = d_wdata;
  assign io_dmemWEn   = d_wr;
  assign io_dmemREn   = d_rd;
  always_ff @(posedge clock)
    if (reset) begin d_ack_q <= 1'b0; d_tag_q <= 11'd0; d_rdata_q <= 32'd0; end
    else begin
      d_ack_q <= d_req && io_dmemReady;
      if (d_req && io_dmemReady) begin d_tag_q <= d_tag; d_rdata_q <= io_dmemRData; end
    end

  riscv_core #(
    .SUPPORT_BRANCH_PREDICTION (1), .SUPPORT_MULDIV (1), .SUPPORT_SUPER (0), .SUPPORT_MMU (0),
    .SUPPORT_DUAL_ISSUE (1), .SUPPORT_LOAD_BYPASS (1), .SUPPORT_MUL_BYPASS (1),
    .SUPPORT_REGFILE_XILINX (0), .EXTRA_DECODE_STAGE (0)
  ) cpu (
    .clk_i (clock), .rst_i (reset),
    .mem_d_data_rd_i (d_rdata_q), .mem_d_accept_i (io_dmemReady), .mem_d_ack_i (d_ack_q),
    .mem_d_error_i (1'b0), .mem_d_resp_tag_i (d_tag_q),
    .mem_i_accept_i (io_imemReady), .mem_i_valid_i (i_valid_q), .mem_i_error_i (1'b0),
    .mem_i_inst_i (i_inst_q), .intr_i (1'b0), .reset_vector_i (32'h0), .cpu_id_i (32'h0),
    .mem_d_addr_o (d_addr), .mem_d_data_wr_o (d_wdata), .mem_d_rd_o (d_rd), .mem_d_wr_o (d_wr),
    .mem_d_cacheable_o (d_cacheable), .mem_d_req_tag_o (d_tag), .mem_d_invalidate_o (d_inval),
    .mem_d_writeback_o (d_wb), .mem_d_flush_o (d_flush),
    .mem_i_rd_o (i_rd), .mem_i_flush_o (i_flush), .mem_i_invalidate_o (i_inval), .mem_i_pc_o (i_pc)
  );
endmodule
