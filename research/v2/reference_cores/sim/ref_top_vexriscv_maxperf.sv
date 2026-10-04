// Stage 2 adapter: VexRiscv GenFullNoMmuMaxPerf (8 KB I$ and D$) on the
// ref_sim memory interface. Cache refills are 32-byte lines streamed one word
// per ready cycle: the command's accept cycle reads beat 0, each later beat
// takes its own stall draw, and every beat answers one cycle after its read.
// Stores are single write-through beats with no response; uncached loads are
// one beat. Reset vector 0x80000000 (--reset-pc 80000000).
module ref_top (
  input  logic        clock, reset,
  output logic [31:0] io_imemAddr, output logic io_imemReq,
  input  logic [31:0] io_imemData, input logic [31:0] io_imemData1, input logic io_imemReady,
  output logic [31:0] io_dmemAddr, output logic [31:0] io_dmemWData,
  output logic [3:0]  io_dmemWEn,  output logic io_dmemREn,
  input  logic [31:0] io_dmemRData, input logic io_dmemReady
);
  // iBus: 8-beat line refills.
  logic        i_cmd_valid, i_cmd_ready, i_rsp_valid, ibusy;
  logic [31:0] i_cmd_addr, i_rsp_data, ibase;
  logic [2:0]  i_cmd_size, ibeat;
  assign io_imemReq  = ibusy || i_cmd_valid;
  assign io_imemAddr = ibusy ? {ibase[31:5], ibeat, 2'b00} : {i_cmd_addr[31:5], 5'b0};
  assign i_cmd_ready = !ibusy && io_imemReady;
  always_ff @(posedge clock)
    if (reset) begin ibusy <= 1'b0; ibeat <= 3'd0; i_rsp_valid <= 1'b0; end
    else begin
      i_rsp_valid <= io_imemReq && io_imemReady;
      if (io_imemReq && io_imemReady) begin
        i_rsp_data <= io_imemData;
        if (!ibusy) begin ibusy <= 1'b1; ibase <= i_cmd_addr; ibeat <= 3'd1; end
        else begin ibeat <= ibeat + 3'd1; if (ibeat == 3'd7) ibusy <= 1'b0; end
      end
    end

  // dBus: write-through single-beat stores; loads are 8-beat line refills
  // (size 5) or single beats.
  logic        d_cmd_valid, d_cmd_ready, d_cmd_wr, d_cmd_uncached, d_cmd_last;
  logic [31:0] d_cmd_addr, d_cmd_data, d_rsp_data, dbase;
  logic [3:0]  d_cmd_mask;
  logic [2:0]  d_cmd_size, dbeat, dlen;
  logic        dbusy, d_rsp_valid, d_rsp_last, d_new_read, d_fire;
  assign d_new_read   = !dbusy && d_cmd_valid && !d_cmd_wr;
  assign io_dmemAddr  = dbusy ? {dbase[31:5], dbeat, 2'b00}
                      : (d_cmd_size == 3'd5 ? {d_cmd_addr[31:5], 5'b0} : d_cmd_addr);
  assign io_dmemWData = d_cmd_data;
  assign io_dmemWEn   = (!dbusy && d_cmd_valid && d_cmd_wr) ? d_cmd_mask : 4'b0;
  assign io_dmemREn   = dbusy || d_new_read;
  assign d_cmd_ready  = !dbusy && io_dmemReady;
  assign d_fire       = (dbusy || d_cmd_valid) && io_dmemReady;
  always_ff @(posedge clock)
    if (reset) begin dbusy <= 1'b0; dbeat <= 3'd0; dlen <= 3'd0; d_rsp_valid <= 1'b0; d_rsp_last <= 1'b0; end
    else begin
      d_rsp_valid <= d_fire && (dbusy || !d_cmd_wr);
      if (d_fire && (dbusy || !d_cmd_wr)) d_rsp_data <= io_dmemRData;
      if (d_fire && d_new_read) begin
        if (d_cmd_size == 3'd5) begin
          dbusy <= 1'b1; dbase <= d_cmd_addr; dbeat <= 3'd1; dlen <= 3'd7; d_rsp_last <= 1'b0;
        end else d_rsp_last <= 1'b1;
      end else if (d_fire && dbusy) begin
        dbeat <= dbeat + 3'd1;
        d_rsp_last <= (dbeat == dlen);
        if (dbeat == dlen) dbusy <= 1'b0;
      end
    end

  VexRiscv cpu (
    .clk (clock), .reset (reset), .debugReset (reset),
    .iBus_cmd_valid (i_cmd_valid), .iBus_cmd_ready (i_cmd_ready),
    .iBus_cmd_payload_address (i_cmd_addr), .iBus_cmd_payload_size (i_cmd_size),
    .iBus_rsp_valid (i_rsp_valid), .iBus_rsp_payload_data (i_rsp_data), .iBus_rsp_payload_error (1'b0),
    .dBus_cmd_valid (d_cmd_valid), .dBus_cmd_ready (d_cmd_ready), .dBus_cmd_payload_wr (d_cmd_wr),
    .dBus_cmd_payload_uncached (d_cmd_uncached), .dBus_cmd_payload_address (d_cmd_addr),
    .dBus_cmd_payload_data (d_cmd_data), .dBus_cmd_payload_mask (d_cmd_mask),
    .dBus_cmd_payload_size (d_cmd_size), .dBus_cmd_payload_last (d_cmd_last),
    .dBus_rsp_valid (d_rsp_valid), .dBus_rsp_payload_last (d_rsp_last),
    .dBus_rsp_payload_data (d_rsp_data), .dBus_rsp_payload_error (1'b0),
    .timerInterrupt (1'b0), .externalInterrupt (1'b0), .softwareInterrupt (1'b0),
    .debug_bus_cmd_valid (1'b0), .debug_bus_cmd_ready (), .debug_bus_cmd_payload_wr (1'b0),
    .debug_bus_cmd_payload_address (8'd0), .debug_bus_cmd_payload_data (32'd0),
    .debug_bus_rsp_data (), .debug_resetOut ()
  );
endmodule
