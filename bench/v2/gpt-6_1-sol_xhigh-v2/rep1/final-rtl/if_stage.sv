// rtl/if_stage.sv
//
// Instruction fetch stage. A one-entry fall-through skid buffer captures
// ready fetches while ID is held. The empty-buffer path remains combinational
// so ID/EX can accept the current fetch without an extra pipeline cycle.
//
// The tagged next-PC table reads only the registered fetch PC.
// Each queued token retains the exact prediction used to advance fetch.
// Recovery cancels the queue; ID kills validity and side effects rather than
// putting recovery on the decode data path.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // offered ID token backpressure
  input  logic              imem_ready,
  input  logic              redirect,         // pending EX/MEM recovery
  input  logic [31:0]       redirect_target,
  input  predictor_update_t update,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] predicted_next_pc;
  logic [63:0] valid_q;
  logic [23:0] tags [0:63];
  logic [29:0] targets [0:63];
  logic unconditional [0:63];
  logic [1:0] counters [0:63];
  logic [5:0] lookup_index, update_index;
  logic lookup_hit, update_hit;
  if_id_t fetch_token, skid_q;
  logic fetch_accept;

  assign lookup_index = pc[7:2];
  assign update_index = update.pc[7:2];
  assign lookup_hit = valid_q[lookup_index] && tags[lookup_index] == pc[31:8];
  assign update_hit = valid_q[update_index] && tags[update_index] == update.pc[31:8];

  always_comb begin
    predicted_next_pc = pc + 32'd4;
    if (lookup_hit && (unconditional[lookup_index] || counters[lookup_index][1]))
      predicted_next_pc = {targets[lookup_index], 2'b00};
  end

  // Only validity resets. The payload memories have asynchronous reads and
  // synchronous writes, allowing distributed RAM inference. There is no
  // same-cycle training bypass into the lookup or captured prediction.
  always_ff @(posedge clock) begin
    if (reset) valid_q <= '0;
    else if (update.valid) begin
      if (update.allocate) valid_q[update_index] <= 1'b1;
      else if (update_hit) valid_q[update_index] <= 1'b0;
    end
  end

  always_ff @(posedge clock) begin
    if (!reset && update.valid && update.allocate) begin
      tags[update_index] <= update.pc[31:8];
      targets[update_index] <= update.target[31:2];
      unconditional[update_index] <= update.unconditional;
      if (!update_hit)
        counters[update_index] <= update.taken ? 2'b10 : 2'b01;
      else if (update.taken) begin
        if (counters[update_index] != 2'b11)
          counters[update_index] <= counters[update_index] + 2'b01;
      end else begin
        if (counters[update_index] != 2'b00)
          counters[update_index] <= counters[update_index] - 2'b01;
      end
    end
  end

  // An empty entry can accept even while ID is held. A full entry can
  // accept only when its head drains, replacing that head at the same edge.
  // Neither the queue nor ID consumes the same raw fetch twice.
  assign fetch_accept = imem_ready && (!skid_q.valid || !stall);

  // Recovery overrides a full queue and an unavailable imem bus. Its older
  // owner retains the event and target across dmem holds; repeated recovery
  // edges keep the queue empty until ID can annul its held younger token.
  // Only an accepted fetch advances on prediction.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (fetch_accept) pc <= predicted_next_pc;
  end

  // Redirect discards both the queued younger instruction and any same-edge
  // raw fetch. Queue ownership depends only on this narrow validity bit.
  always_ff @(posedge clock) begin
    if (reset || redirect) begin
      skid_q.valid <= 1'b0;
    end else if (fetch_accept) begin
      skid_q.valid <= skid_q.valid || stall;
    end else if (!stall) begin
      skid_q.valid <= 1'b0;
    end
  end

  // Payload needs neither reset nor recovery gating. Also capturing bypassed
  // fetches simplifies the wide enable; without validity this data is unused.
  always_ff @(posedge clock) begin
    if (fetch_accept) begin
      skid_q.pc                <= fetch_token.pc;
      skid_q.predicted_next_pc <= fetch_token.predicted_next_pc;
      skid_q.instr             <= fetch_token.instr;
    end
  end

  assign imem_addr = pc;

  always_comb begin
    fetch_token.pc                = pc;
    fetch_token.predicted_next_pc = predicted_next_pc;
    fetch_token.instr             = imem_data;
    fetch_token.valid             = imem_ready;
    out = skid_q.valid ? skid_q : fetch_token;
  end

endmodule
