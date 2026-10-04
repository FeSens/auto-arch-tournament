// Stage 2 adapter: VexRiscv GenFullNoMmuNoCache on the ref_sim memory
// interface. IBusSimple/DBusSimple: command accepted on the stall draw,
// response one cycle later (stores have none). Reset vector 0x80000000, so
// ref_sim runs it with --reset-pc 80000000.
module ref_top (
  input  logic        clock, reset,
  output logic [31:0] io_imemAddr, output logic io_imemReq,
  input  logic [31:0] io_imemData, input logic [31:0] io_imemData1, input logic io_imemReady,
  output logic [31:0] io_dmemAddr, output logic [31:0] io_dmemWData,
  output logic [3:0]  io_dmemWEn,  output logic io_dmemREn,
  input  logic [31:0] io_dmemRData, input logic io_dmemReady
);
  logic        i_cmd_valid, i_rsp_valid, d_cmd_valid, d_cmd_wr, d_rsp_ready;
  logic [31:0] i_cmd_pc, i_rsp_inst, d_cmd_addr, d_cmd_data, d_rsp_data;
  logic [3:0]  d_cmd_mask;
  logic [1:0]  d_cmd_size;
  assign io_imemReq   = i_cmd_valid;
  assign io_imemAddr  = i_cmd_pc;
  assign io_dmemAddr  = d_cmd_addr;
  assign io_dmemWData = d_cmd_data;
  assign io_dmemWEn   = (d_cmd_valid && d_cmd_wr) ? d_cmd_mask : 4'b0;
  assign io_dmemREn   = d_cmd_valid && !d_cmd_wr;
  always_ff @(posedge clock)
    if (reset) begin i_rsp_valid <= 1'b0; d_rsp_ready <= 1'b0; end
    else begin
      i_rsp_valid <= i_cmd_valid && io_imemReady;
      if (i_cmd_valid && io_imemReady) i_rsp_inst <= io_imemData;
      d_rsp_ready <= d_cmd_valid && io_dmemReady && !d_cmd_wr;
      if (d_cmd_valid && io_dmemReady) d_rsp_data <= io_dmemRData;
    end
  VexRiscv cpu (
    .clk (clock), .reset (reset), .debugReset (reset),
    .iBus_cmd_valid (i_cmd_valid), .iBus_cmd_ready (io_imemReady), .iBus_cmd_payload_pc (i_cmd_pc),
    .iBus_rsp_valid (i_rsp_valid), .iBus_rsp_payload_error (1'b0), .iBus_rsp_payload_inst (i_rsp_inst),
    .dBus_cmd_valid (d_cmd_valid), .dBus_cmd_ready (io_dmemReady), .dBus_cmd_payload_wr (d_cmd_wr),
    .dBus_cmd_payload_mask (d_cmd_mask), .dBus_cmd_payload_address (d_cmd_addr),
    .dBus_cmd_payload_data (d_cmd_data), .dBus_cmd_payload_size (d_cmd_size),
    .dBus_rsp_ready (d_rsp_ready), .dBus_rsp_error (1'b0), .dBus_rsp_data (d_rsp_data),
    .timerInterrupt (1'b0), .externalInterrupt (1'b0), .softwareInterrupt (1'b0),
    .debug_bus_cmd_valid (1'b0), .debug_bus_cmd_ready (), .debug_bus_cmd_payload_wr (1'b0),
    .debug_bus_cmd_payload_address (8'd0), .debug_bus_cmd_payload_data (32'd0),
    .debug_bus_rsp_data (), .debug_resetOut ()
  );
endmodule
