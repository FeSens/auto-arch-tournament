// Stage 2 adapter: VexiiRiscv rv32im branchPredict (bench memory map, reset
// vector 0) on the ref_sim memory interface. Every fetch and LSU command gets
// one response one cycle after it is accepted on the stall draw, with its id.
module ref_top (
  input  logic        clock, reset,
  output logic [31:0] io_imemAddr, output logic io_imemReq,
  input  logic [31:0] io_imemData, input logic [31:0] io_imemData1, input logic io_imemReady,
  output logic [31:0] io_dmemAddr, output logic [31:0] io_dmemWData,
  output logic [3:0]  io_dmemWEn,  output logic io_dmemREn,
  input  logic [31:0] io_dmemRData, input logic io_dmemReady
);
  logic        f_cmd_valid, f_rsp_valid;
  logic [0:0]  f_cmd_id, f_rsp_id;
  logic [31:0] f_cmd_addr, f_rsp_word;
  logic        l_cmd_valid, l_cmd_write, l_cmd_io, l_cmd_from_hart, l_rsp_valid;
  logic [0:0]  l_cmd_id, l_rsp_id;
  logic [31:0] l_cmd_addr, l_cmd_data, l_rsp_data;
  logic [1:0]  l_cmd_size;
  logic [3:0]  l_cmd_mask;
  logic [15:0] l_cmd_uop;
  assign io_imemReq   = f_cmd_valid;
  assign io_imemAddr  = f_cmd_addr;
  assign io_dmemAddr  = l_cmd_addr;
  assign io_dmemWData = l_cmd_data;
  assign io_dmemWEn   = (l_cmd_valid && l_cmd_write) ? l_cmd_mask : 4'b0;
  assign io_dmemREn   = l_cmd_valid && !l_cmd_write;
  always_ff @(posedge clock)
    if (reset) begin f_rsp_valid <= 1'b0; l_rsp_valid <= 1'b0; end
    else begin
      f_rsp_valid <= f_cmd_valid && io_imemReady;
      if (f_cmd_valid && io_imemReady) begin f_rsp_id <= f_cmd_id; f_rsp_word <= io_imemData; end
      l_rsp_valid <= l_cmd_valid && io_dmemReady;
      if (l_cmd_valid && io_dmemReady) begin l_rsp_id <= l_cmd_id; l_rsp_data <= io_dmemRData; end
    end

  VexiiRiscv cpu (
    .PrivilegedPlugin_logic_rdtime                     (64'd0),
    .PrivilegedPlugin_logic_harts_0_int_m_timer        (1'b0),
    .PrivilegedPlugin_logic_harts_0_int_m_software     (1'b0),
    .PrivilegedPlugin_logic_harts_0_int_m_external     (1'b0),
    .FetchCachelessPlugin_logic_bus_cmd_valid          (f_cmd_valid),
    .FetchCachelessPlugin_logic_bus_cmd_ready          (io_imemReady),
    .FetchCachelessPlugin_logic_bus_cmd_payload_id     (f_cmd_id),
    .FetchCachelessPlugin_logic_bus_cmd_payload_address(f_cmd_addr),
    .FetchCachelessPlugin_logic_bus_rsp_valid          (f_rsp_valid),
    .FetchCachelessPlugin_logic_bus_rsp_payload_id     (f_rsp_id),
    .FetchCachelessPlugin_logic_bus_rsp_payload_error  (1'b0),
    .FetchCachelessPlugin_logic_bus_rsp_payload_word   (f_rsp_word),
    .LsuCachelessPlugin_logic_bus_cmd_valid            (l_cmd_valid),
    .LsuCachelessPlugin_logic_bus_cmd_ready            (io_dmemReady),
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

endmodule
