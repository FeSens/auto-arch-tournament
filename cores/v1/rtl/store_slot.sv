// rtl/store_slot.sv
//
// One-entry pending-store retirement slot. It is allocated only for an
// aligned, legal normal-RAM store that reached MEM while dmemReady was low.
// The instruction retires through MEM/WB on the enqueue cycle; this slot
// later drains the physical write to the dmem port.
module store_slot (
  input  logic        clock,
  input  logic        reset,

  input  logic        enqueue,
  input  logic [31:0] enqueue_addr,
  input  logic [31:0] enqueue_wdata,
  input  logic [3:0]  enqueue_wmask,

  input  logic        drain_ready,
  output logic        valid,
  output logic [31:0] drain_addr,
  output logic [31:0] drain_wdata,
  output logic [3:0]  drain_wmask
);

  logic        valid_q;
  logic [31:0] addr_q;
  logic [31:0] wdata_q;
  logic [3:0]  wmask_q;
  logic        drain_fire;

  assign drain_fire = valid_q && drain_ready;

  always_ff @(posedge clock) begin
    if (reset) begin
      valid_q <= 1'b0;
      addr_q  <= 32'b0;
      wdata_q <= 32'b0;
      wmask_q <= 4'b0000;
    end else begin
      if (drain_fire && !enqueue) begin
        valid_q <= 1'b0;
      end else if (enqueue) begin
        valid_q <= 1'b1;
        addr_q  <= enqueue_addr;
        wdata_q <= enqueue_wdata;
        wmask_q <= enqueue_wmask;
      end
    end
  end

  assign valid       = valid_q;
  assign drain_addr  = addr_q;
  assign drain_wdata = wdata_q;
  assign drain_wmask = wmask_q;

endmodule
