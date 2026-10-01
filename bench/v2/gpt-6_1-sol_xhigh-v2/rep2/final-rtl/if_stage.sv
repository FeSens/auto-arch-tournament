// rtl/if_stage.sv
//
// Instruction fetch stage. A two-entry elastic queue retains predicted-path
// fetches while decode is held. An empty queue falls through to ID/EX without
// adding a pipeline stage; fetch traversal is independent of decode holds.
//
// A fully tagged 64-entry next-PC table is read alongside imem. The exact
// prediction travels with each accepted instruction. Recovery invalidates
// younger work without changing its raw instruction or decoder inputs.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              decode_hold,      // ID/EX cannot accept the head
  input  logic              imem_ready,       // raw bus response availability
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  input  logic              train_valid,      // one valid EX advance
  /* verilator lint_off UNUSEDSIGNAL */
  // The table stores aligned PCs/targets; EX validates target low bits.
  input  logic [31:0]       train_pc,
  input  logic [31:0]       train_target,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic              train_install,    // legal aligned control flow
  input  logic              train_conditional,
  input  logic              train_taken,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output logic              fetch_available,  // independent of EX correction
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [63:0] valid_q;
  logic [23:0] tag_q [0:63];
  logic [29:0] target_q [0:63];
  logic conditional_q [0:63];
  logic [1:0] counter_q [0:63];
  logic lookup_hit, train_match;
  logic [5:0] lookup_index, train_index;

  logic [31:0] queued_pc [0:1];
  logic [31:0] queued_instr [0:1];
  logic [31:0] queued_prediction [0:1];
  logic [1:0] count_q;
  logic read_q, write_q;
  logic queue_pop, fetch_accept, queue_push;

  assign fetch_available = !reset && ((count_q != 0) || imem_ready);
  assign queue_pop = (count_q != 0) && !decode_hold;
  assign fetch_accept = imem_ready && ((count_q != 2) || queue_pop);
  // A consumed empty-queue fetch goes straight into ID/EX. Otherwise retain
  // the response, including a replacement for a simultaneously consumed head.
  assign queue_push = fetch_accept && ((count_q != 0) || decode_hold);

  // Payload clock enables depend only on bus acceptance and decode hold.
  // Correction clears occupancy below, making any coincident write invisible.
  // Nonblocking writes preserve the old head on a full simultaneous transfer.
  always_ff @(posedge clock) begin
    if (!reset && queue_push) begin
      queued_pc[write_q] <= pc;
      queued_instr[write_q] <= imem_data;
      queued_prediction[write_q] <= next_pc;
    end
  end

  always_ff @(posedge clock) begin
    if (reset || redirect) begin
      count_q <= '0;
      read_q <= 1'b0;
      write_q <= 1'b0;
    end else begin
      if (queue_pop) read_q <= !read_q;
      if (queue_push) write_q <= !write_q;
      case ({queue_push, queue_pop})
        2'b10: count_q <= count_q + 2'd1;
        2'b01: count_q <= count_q - 2'd1;
        default: ;
      endcase
    end
  end

  assign lookup_index = pc[7:2];
  assign train_index = train_pc[7:2];
  assign lookup_hit = valid_q[lookup_index] &&
                      (tag_q[lookup_index] == pc[31:8]);
  assign train_match = valid_q[train_index] &&
                       (tag_q[train_index] == train_pc[31:8]);
  assign next_pc = (lookup_hit &&
                    (!conditional_q[lookup_index] || counter_q[lookup_index][1]))
                 ? {target_q[lookup_index], 2'b00} : pc + 32'd4;

  // Only validity is reset. Unreset payload arrays can infer distributed
  // memory; old-data lookup on an update is covered by saved prediction.
  always_ff @(posedge clock) begin
    if (reset) valid_q <= '0;
    else if (train_valid) begin
      if (train_install) valid_q[train_index] <= 1'b1;
      else if (train_match) valid_q[train_index] <= 1'b0;
    end
  end

  always_ff @(posedge clock) begin
    if (!reset && train_valid && train_install) begin
      tag_q[train_index] <= train_pc[31:8];
      target_q[train_index] <= train_target[31:2];
      conditional_q[train_index] <= train_conditional;
      if (train_conditional && train_match && conditional_q[train_index]) begin
        if (train_taken)
          counter_q[train_index] <= (counter_q[train_index] == 2'b11)
                                  ? 2'b11 : counter_q[train_index] + 2'b01;
        else
          counter_q[train_index] <= (counter_q[train_index] == 2'b00)
                                  ? 2'b00 : counter_q[train_index] - 2'b01;
      end else begin
        counter_q[train_index] <= train_taken ? 2'b10 : 2'b01;
      end
    end
  end

  // Advancing EX correction overrides a full queue and either bus/decode hold.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (fetch_accept) pc <= next_pc;
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc    = (count_q != 0) ? queued_pc[read_q] : pc;
    out.instr = (count_q != 0) ? queued_instr[read_q] : imem_data;
    out.predicted_next_pc = (count_q != 0) ? queued_prediction[read_q] : next_pc;
    out.valid = fetch_available;
  end

endmodule
