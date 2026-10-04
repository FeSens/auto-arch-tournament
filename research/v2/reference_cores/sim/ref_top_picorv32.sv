// Stage 2 adapter: PicoRV32 (same parameters as benches/picorv32_bench.sv) on
// the ref_sim memory interface. One valid/ready bus; mem_instr selects the
// imem or dmem port and its stall draw; data returns the cycle after accept.
module ref_top (
  input  logic        clock, reset,
  output logic [31:0] io_imemAddr, output logic io_imemReq,
  input  logic [31:0] io_imemData, input logic [31:0] io_imemData1, input logic io_imemReady,
  output logic [31:0] io_dmemAddr, output logic [31:0] io_dmemWData,
  output logic [3:0]  io_dmemWEn,  output logic io_dmemREn,
  input  logic [31:0] io_dmemRData, input logic io_dmemReady
);
  logic        mem_valid, mem_instr, mem_ready, trap;
  logic [31:0] mem_addr, mem_wdata, mem_rdata;
  logic [3:0]  mem_wstrb;

  logic req_i, req_d, fire;
  assign req_i = mem_valid && !mem_ready && mem_instr;
  assign req_d = mem_valid && !mem_ready && !mem_instr;
  assign io_imemReq  = req_i;
  assign io_imemAddr = mem_addr;
  assign io_dmemAddr = mem_addr;
  assign io_dmemWData = mem_wdata;
  assign io_dmemWEn  = req_d ? mem_wstrb : 4'b0;
  assign io_dmemREn  = req_d && (mem_wstrb == 4'b0);
  assign fire = (req_i && io_imemReady) || (req_d && io_dmemReady);

  always_ff @(posedge clock)
    if (reset) begin mem_ready <= 1'b0; mem_rdata <= 32'd0; end
    else begin
      mem_ready <= fire;
      if (fire) mem_rdata <= mem_instr ? io_imemData : io_dmemRData;
    end

  picorv32 #(
    .BARREL_SHIFTER (1), .ENABLE_MUL (0), .ENABLE_FAST_MUL (1), .ENABLE_DIV (1),
    .COMPRESSED_ISA (0), .ENABLE_IRQ (0)
  ) cpu (
    .clk (clock), .resetn (!reset), .trap (trap),
    .mem_valid (mem_valid), .mem_instr (mem_instr), .mem_ready (mem_ready),
    .mem_addr (mem_addr), .mem_wdata (mem_wdata), .mem_wstrb (mem_wstrb), .mem_rdata (mem_rdata),
    .mem_la_read (), .mem_la_write (), .mem_la_addr (), .mem_la_wdata (), .mem_la_wstrb (),
    .pcpi_valid (), .pcpi_insn (), .pcpi_rs1 (), .pcpi_rs2 (),
    .pcpi_wr (1'b0), .pcpi_rd (32'd0), .pcpi_wait (1'b0), .pcpi_ready (1'b0),
    .irq (32'd0), .eoi (), .trace_valid (), .trace_data ()
  );
endmodule
