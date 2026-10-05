// 64-entry direct-mapped target/direction predictor for the lower 1 MiB.
// Only validity resets. Payload arrays have asynchronous reads and one
// synchronous write port; lookup observes the old row on an update edge.
module branch_predictor (
  input  logic        clock,
  input  logic        reset,
  input  logic [31:0] lookup_pc,
  output logic        predicted_taken,
  output logic [31:0] predicted_target,
  input  logic        update_en,
  input  logic [31:0] update_pc,
  input  logic        update_branch,
  input  logic        update_jump,
  input  logic        update_legal,
  input  logic        update_taken,
  input  logic [31:0] update_target
);
  logic [63:0] valid_q;
  logic [11:0] tag_q [0:63];
  logic [17:0] target_q [0:63];
  logic [1:0]  counter_q [0:63];
  logic        jump_q [0:63];
  logic [5:0] lookup_index, update_index;
  logic lookup_in_range, update_in_range, target_in_range;
  logic update_hit;
  logic [1:0] next_counter;

  assign lookup_index = lookup_pc[7:2];
  assign update_index = update_pc[7:2];
  assign lookup_in_range = lookup_pc[31:20] == 12'b0 && lookup_pc[1:0] == 2'b0;
  assign update_in_range = update_pc[31:20] == 12'b0 && update_pc[1:0] == 2'b0;
  assign target_in_range = update_target[31:20] == 12'b0 && update_target[1:0] == 2'b0;

  always_comb begin
    predicted_taken = 1'b0;
    predicted_target = 32'b0;
    if (lookup_in_range && valid_q[lookup_index]) begin
      if (tag_q[lookup_index] == lookup_pc[19:8]) begin
        predicted_taken = jump_q[lookup_index] || counter_q[lookup_index][1];
        predicted_target = {12'b0, target_q[lookup_index], 2'b0};
      end
    end
  end

  always_comb begin
    update_hit = 1'b0;
    if (update_in_range && valid_q[update_index])
      update_hit = tag_q[update_index] == update_pc[19:8];

    // A replacement (including a change from jump to branch) starts weak.
    next_counter = update_taken ? 2'b10 : 2'b01;
    if (update_hit && !jump_q[update_index]) begin
      next_counter = counter_q[update_index];
      if (update_taken && counter_q[update_index] != 2'b11)
        next_counter = counter_q[update_index] + 2'b01;
      else if (!update_taken && counter_q[update_index] != 2'b00)
        next_counter = counter_q[update_index] - 2'b01;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      valid_q <= 64'b0;
    end else if (update_en && update_in_range) begin
      if (update_legal && (update_branch || update_jump) && target_in_range) begin
        valid_q[update_index] <= 1'b1;
        tag_q[update_index] <= update_pc[19:8];
        target_q[update_index] <= update_target[19:2];
        counter_q[update_index] <= update_jump ? 2'b10 : next_counter;
        jump_q[update_index] <= update_jump;
      end else if (update_hit) begin
        // Ordinary/stale, illegal, trapping and unrepresentable targets
        // invalidate only their own PC, never another tag's entry.
        valid_q[update_index] <= 1'b0;
      end
    end
  end
endmodule
