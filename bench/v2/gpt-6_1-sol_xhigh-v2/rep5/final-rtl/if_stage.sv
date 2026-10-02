// rtl/if_stage.sv
//
// Three ordered fixed-position fetch records isolate decode from the bus
// and predictor lookup. Empty storage has no live instruction bypass.
// Training captures an accepted event and its selected row; maintenance
// commits one edge later, independently of queue and backend transfers.
//
// Latency:        strictly registered fetch and training ingress.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // decoded/operand-read backpressure
  input  logic              redirect,         // accepted registered MEM recovery
  input  logic [31:0]       redirect_target,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  input  logic              train_valid,      // exactly one MEM acceptance
  input  logic [31:0]       train_pc,
  input  logic              train_eligible,   // legal, aligned control transfer
  input  logic              train_jump,
  input  logic              train_taken,
  input  logic [31:0]       train_target,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [31:0] valid_q;
  logic [24:0] tags [0:31];
  logic [29:0] targets [0:31];
  logic [1:0] counters [0:31];
  logic [4:0] fetch_index, train_index;
  logic fetch_hit, prediction_selected;

  if_id_t head_q, middle_q, tail_q, fetched;
  logic [1:0] occupancy_q;
  logic enqueue, dequeue;

  // The table read ends at these flops. Same-row forwarding uses the
  // older event's complete post-update row, including replacements and
  // invalidations, rather than re-reading a stale pre-commit row.
  logic training_q, eligible_q, jump_q, taken_q;
  logic [4:0] training_index_q;
  logic [24:0] training_tag_q, row_tag_q;
  // Retain the aligned full address; low bits are constant zero.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] training_target_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic row_valid_q;
  logic [1:0] row_counter_q;
  logic training_hit, commit_write, post_valid;
  logic [24:0] post_tag;
  logic [1:0] post_counter;

  assign fetch_index = pc[6:2];
  assign train_index = train_pc[6:2];
  assign fetch_hit = valid_q[fetch_index] && tags[fetch_index] == pc[31:7];
  assign prediction_selected = fetch_hit && counters[fetch_index][1];

  assign training_hit = row_valid_q && row_tag_q == training_tag_q;
  always_comb begin
    post_valid = row_valid_q;
    post_tag = row_tag_q;
    post_counter = row_counter_q;
    commit_write = training_q && (eligible_q || training_hit);
    if (eligible_q) begin
      post_valid = 1'b1;
      post_tag = training_tag_q;
      if (jump_q) post_counter = 2'b11;
      else if (!training_hit) post_counter = taken_q ? 2'b10 : 2'b01;
      // Direct Boolean saturating transitions avoid an arithmetic carry
      // chain between the row snapshot and the next snapshot/commit.
      else if (taken_q)
        post_counter = {row_counter_q[1] | row_counter_q[0],
                        row_counter_q[1] | !row_counter_q[0]};
      else
        post_counter = {row_counter_q[1] & row_counter_q[0],
                        row_counter_q[1] & !row_counter_q[0]};
    end else if (training_hit) post_valid = 1'b0;
  end

  // Reset cancels pending events as well as committed table validity.
  // Recovery preserves both the older commit and its own accepted event.
  always_ff @(posedge clock) begin
    if (reset) begin
      valid_q <= '0;
      training_q <= 1'b0;
      eligible_q <= 1'b0;
      jump_q <= 1'b0;
      taken_q <= 1'b0;
      training_index_q <= '0;
      training_tag_q <= '0;
      training_target_q <= '0;
      row_valid_q <= 1'b0;
      row_tag_q <= '0;
      row_counter_q <= '0;
    end else begin
      if (commit_write) begin
        valid_q[training_index_q] <= post_valid;
        if (eligible_q) begin
          tags[training_index_q] <= post_tag;
          targets[training_index_q] <= training_target_q[31:2];
          counters[training_index_q] <= post_counter;
        end
      end
      training_q <= train_valid;
      if (train_valid) begin
        training_index_q <= train_index;
        training_tag_q <= train_pc[31:7];
        training_target_q <= {train_target[31:2], 2'b00};
        eligible_q <= train_eligible && train_pc[1:0] == 2'b00 &&
                      train_target[1:0] == 2'b00;
        jump_q <= train_jump;
        taken_q <= train_taken;
        if (training_q && training_index_q == train_index) begin
          row_valid_q <= post_valid;
          row_tag_q <= post_tag;
          row_counter_q <= post_counter;
        end else begin
          row_valid_q <= valid_q[train_index];
          row_tag_q <= tags[train_index];
          row_counter_q <= counters[train_index];
        end
      end
    end
  end

  always_comb begin
    next_pc = prediction_selected ? {targets[fetch_index], 2'b00} : pc + 32'd4;
  end

  // Queue capacity, not backend/bus readiness together, accepts fetch.
  // Full simultaneous pop/push keeps all three positions occupied.
  assign dequeue = head_q.valid && !stall && !redirect && !reset;
  assign enqueue = imem_ready && (occupancy_q != 2'd3 || dequeue) &&
                   !redirect && !reset;
  always_comb begin
    fetched.pc = pc;
    fetched.instr = imem_data;
    fetched.prediction_selected = prediction_selected;
    fetched.predicted_target = {targets[fetch_index], 2'b00};
    fetched.valid = 1'b1;
  end

  // Every raw output word comes from the fixed head flops. Occupancy only
  // selects local register writes; it never selects decode or RF words.
  always_ff @(posedge clock) begin
    if (reset || redirect) begin
      occupancy_q <= '0;
      head_q <= '0;
      middle_q <= '0;
      tail_q <= '0;
    end else begin
      case ({enqueue, dequeue})
        2'b10: occupancy_q <= occupancy_q + 2'd1;
        2'b01: occupancy_q <= occupancy_q - 2'd1;
        default: ;
      endcase
      if (dequeue && occupancy_q > 2'd1) head_q <= middle_q;
      else if (enqueue && (occupancy_q == 2'd0 ||
                           (dequeue && occupancy_q == 2'd1))) head_q <= fetched;
      else if (dequeue) head_q.valid <= 1'b0;

      if (dequeue && occupancy_q == 2'd3) middle_q <= tail_q;
      else if (enqueue && ((occupancy_q == 2'd1 && !dequeue) ||
                            (occupancy_q == 2'd2 && dequeue))) middle_q <= fetched;
      else if (dequeue) middle_q.valid <= 1'b0;

      if (enqueue && ((occupancy_q == 2'd2 && !dequeue) ||
                      (occupancy_q == 2'd3 && dequeue))) tail_q <= fetched;
      else if (dequeue) tail_q.valid <= 1'b0;
    end
  end

  // Accepted MEM recovery dominates every hold and suppresses both local
  // transfers. Only an accepted enqueue advances the full fetch PC.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (enqueue)  pc <= next_pc;
  end

  assign imem_addr = pc;
  assign out = head_q;

endmodule
