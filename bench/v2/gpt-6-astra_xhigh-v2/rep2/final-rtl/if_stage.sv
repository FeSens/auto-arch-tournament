// rtl/if_stage.sv
//
// Instruction fetch stage with a four-entry circular fall-through queue.
// The speculative PC advances when the live word is consumed or buffered;
// decode sees the oldest packet's PC and its original fetch prediction.
// An empty queue bypasses the bus without adding an instruction cycle.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // block head consumption
  input  logic              imem_ready,
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              train_valid,
  input  logic [5:0]        train_index,
  input  logic              train_taken,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [1:0] counters [0:63];
  logic train_valid_q, train_taken_q;
  logic [5:0] train_index_q;
  logic is_branch, is_jal, predicted_taken;
  logic [31:0] direct_imm, direct_target;
  if_id_t fetch_packet;
  // Yosys loses the unpacked dimension on this struct typedef. Keep the
  // identical 66-bit packed layout and all FIFO logic shared; Gowin uses
  // the struct array for its measured distributed-storage mapping.
`ifdef YOSYS
  logic [65:0] entries [0:3];
`else
  if_id_t entries [0:3];
`endif
  logic [1:0] rd_ptr, wr_ptr;
  logic [2:0] count;
  logic consume, dequeue, fetch_accept, enqueue;

  // Advisory history starts weakly taken and survives runtime reset.
  initial begin
    for (int i = 0; i < 64; i++) counters[i] = 2'b10;
  end

  // EX supplies a one-cycle event for each accepted conditional branch.
  // Capture every cycle, including bubbles, independently of fetch holds
  // and recovery. Reset discards the pending event, but not table history.
  always_ff @(posedge clock) begin
    if (reset) begin
      train_valid_q <= 1'b0;
      train_index_q <= 6'b0;
      train_taken_q <= 1'b0;
    end else begin
      train_valid_q <= train_valid;
      train_index_q <= train_index;
      train_taken_q <= train_taken;
    end
  end

  // Read the current entry when the saved event drains, so consecutive
  // aliased outcomes accumulate. Fetch still observes pre-edge history.
  always_ff @(posedge clock) begin
    if (!reset && train_valid_q) begin
      if (train_taken_q) begin
        if (counters[train_index_q] != 2'b11)
          counters[train_index_q] <= counters[train_index_q] + 2'b01;
      end else begin
        if (counters[train_index_q] != 2'b00)
          counters[train_index_q] <= counters[train_index_q] - 2'b01;
      end
    end
  end

  always_comb begin
    is_branch = (imem_data[6:0] == 7'b1100011) &&
                (imem_data[14:12] != 3'd2 && imem_data[14:12] != 3'd3);
    is_jal = (imem_data[6:0] == 7'b1101111);
    direct_imm = is_jal
               ? {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
                  imem_data[20], imem_data[30:21], 1'b0}
               : {{19{imem_data[31]}}, imem_data[31], imem_data[7],
                  imem_data[30:25], imem_data[11:8], 1'b0};
    direct_target = pc + direct_imm;
    predicted_taken = (is_jal || (is_branch && counters[pc[7:2]][1])) &&
                      (direct_target[1:0] == 2'b00);
    next_pc = predicted_taken ? direct_target : pc + 32'd4;
  end

  assign consume = out.valid && !stall;
  assign dequeue = consume && (count != 3'd0);
  assign fetch_accept = imem_ready && ((count < 3'd4) || dequeue);
  assign enqueue = fetch_accept && ((count != 3'd0) || !consume);

  // Recovery discards every younger packet even with a full queue or an
  // unavailable bus. Payload RAM is deliberately unreset: count alone
  // determines which entries are live. At full pop/push the combinational
  // read still presents the old head before the nonblocking write edge.
  always_ff @(posedge clock) begin
    if      (reset)        pc <= RESET_PC;
    else if (redirect)     pc <= redirect_target;
    else if (fetch_accept) pc <= next_pc;
  end

  always_ff @(posedge clock) begin
    if (reset || redirect) begin
      count <= 3'd0;
      rd_ptr <= 2'd0;
      wr_ptr <= 2'd0;
    end else begin
      if (enqueue) wr_ptr <= wr_ptr + 2'd1;
      if (dequeue) rd_ptr <= rd_ptr + 2'd1;
      case ({enqueue, dequeue})
        2'b10: count <= count + 3'd1;
        2'b01: count <= count - 3'd1;
        default: ;
      endcase
    end
  end

  always_ff @(posedge clock) begin
    if (!reset && !redirect && enqueue) entries[wr_ptr] <= fetch_packet;
  end

  assign imem_addr = pc;

  always_comb begin
    fetch_packet.pc    = pc;
    fetch_packet.instr = imem_data;
    fetch_packet.predicted_taken = predicted_taken;
    // Payloads enter storage only on a ready fetch; availability of the
    // empty bypass is handled below, without storing a bus-ready signal.
    fetch_packet.valid = 1'b1;
  end

  always_comb begin
    out = entries[rd_ptr];
    if (count == 3'd0) begin
      out = fetch_packet;
      out.valid = imem_ready;
    end
  end

endmodule
