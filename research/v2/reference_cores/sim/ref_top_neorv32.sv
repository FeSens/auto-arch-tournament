// Stage 2 adapter: NEORV32 CPU (benches/neorv32_cpu_flat.vhd, converted to
// Verilog with ghdl --synth) on the ref_sim memory interface. The request
// strobe is single-shot with the request held until ACK; it is accepted on
// the first ready cycle and ACKed one cycle later with the read data.
module ref_top (
  input  logic        clock, reset,
  output logic [31:0] io_imemAddr, output logic io_imemReq,
  input  logic [31:0] io_imemData, input logic [31:0] io_imemData1, input logic io_imemReady,
  output logic [31:0] io_dmemAddr, output logic [31:0] io_dmemWData,
  output logic [3:0]  io_dmemWEn,  output logic io_dmemREn,
  input  logic [31:0] io_dmemRData, input logic io_dmemReady
);
  logic [31:0] i_addr, i_data_q, d_addr, d_wdata, d_data_q;
  logic [4:0]  i_meta, d_meta;
  logic [3:0]  d_ben;
  logic        i_stb, i_pend, i_ack, d_stb, d_rw, d_pend, d_ack, d_req;
  assign io_imemReq  = i_stb || i_pend;
  assign io_imemAddr = i_addr;
  assign d_req        = d_stb || d_pend;
  assign io_dmemAddr  = d_addr;
  assign io_dmemWData = d_wdata;
  assign io_dmemWEn   = (d_req && d_rw) ? d_ben : 4'b0;
  assign io_dmemREn   = d_req && !d_rw;
  always_ff @(posedge clock)
    if (reset) begin i_pend <= 1'b0; i_ack <= 1'b0; d_pend <= 1'b0; d_ack <= 1'b0; end
    else begin
      i_pend <= io_imemReq && !io_imemReady;
      i_ack  <= io_imemReq && io_imemReady;
      if (io_imemReq && io_imemReady) i_data_q <= io_imemData;
      d_pend <= d_req && !io_dmemReady;
      d_ack  <= d_req && io_dmemReady;
      if (d_req && io_dmemReady) d_data_q <= io_dmemRData;
    end
  neorv32_cpu_flat cpu (
    .clk_i (clock), .rstn_i (!reset), .irq_i (3'b0), .sleep_o (), .ifence_o (), .dfence_o (),
    .i_addr_o (i_addr), .i_stb_o (i_stb), .i_meta_o (i_meta), .i_ack_i (i_ack), .i_data_i (i_data_q),
    .d_addr_o (d_addr), .d_wdata_o (d_wdata), .d_ben_o (d_ben), .d_stb_o (d_stb), .d_rw_o (d_rw),
    .d_meta_o (d_meta), .d_ack_i (d_ack), .d_data_i (d_data_q)
  );
endmodule
