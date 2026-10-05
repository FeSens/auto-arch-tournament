// Two-entry elastic fetch queue with an empty combinational bypass.
// Registered occupancy alone controls fetch admission; a full queue
// cannot refill on its dequeue edge. Payload captures are independent
// of consumer hazards and recovery, which only invalidate live tokens.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module fetch_queue (
  input  logic   clock,
  input  logic   reset,
  input  logic   redirect,
  input  logic   imem_ready,
  input  logic   take,
  input  if_id_t raw,
  output logic   capacity,
  output logic   head_ready,
  output if_id_t head
);
  // Stored valid bits are intentionally superseded by live occupancy.
  /* verilator lint_off UNUSEDSIGNAL */
  if_id_t entry0_q;
  if_id_t entry1_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [1:0] count_q;
  logic read_q, write_q;
  logic pop, bypass, push;
  logic select_raw, select_entry0, select_entry1;

  assign head_ready = (count_q != 2'd0) || imem_ready;
  assign capacity = (count_q != 2'd2);
  assign pop = (count_q != 2'd0) && take && !redirect;
  assign bypass = (count_q == 2'd0) && take;
  assign push = imem_ready && capacity && !bypass && !redirect;

  assign select_raw = (count_q == 2'd0);
  assign select_entry0 = (count_q != 2'd0) && !read_q;
  assign select_entry1 = (count_q != 2'd0) && read_q;
  always_comb begin
    // Use the signal width: Yosys does not accept $bits on this typedef.
    head = (raw & {$bits(raw){select_raw}}) |
           (entry0_q & {$bits(raw){select_entry0}}) |
           (entry1_q & {$bits(raw){select_entry1}});
    head.valid = head_ready && !redirect;
  end

  // Each wide register has a constant destination and a local enable.
  // Bypass/reset/recovery may write irrelevant data without making it live.
  always_ff @(posedge clock) begin
    if (imem_ready && capacity && !write_q) entry0_q <= raw;
  end
  always_ff @(posedge clock) begin
    if (imem_ready && capacity && write_q) entry1_q <= raw;
  end

  always_ff @(posedge clock) begin
    if (reset || redirect) begin
      count_q <= 2'd0;
      read_q <= 1'b0;
      write_q <= 1'b0;
    end else begin
      case ({push, pop})
        2'b10: count_q <= count_q + 2'd1;
        2'b01: count_q <= count_q - 2'd1;
        default: ;
      endcase
      if (pop) read_q <= !read_q;
      if (push) write_q <= !write_q;
    end
  end
endmodule
