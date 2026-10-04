// Folded-PC agree predictor. Lookup reads only stored state: neither the
// live resolution nor the queued event bypasses into fetch prediction.
// A branch queues one event when EX advances. The following edge consumes
// it, updating the current counter even if the pipeline has since stalled.
module branch_predictor (
  input  logic        clock,
  input  logic        reset,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] lookup_pc,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic        lookup_bias,
  output logic        predicted_taken,
  input  logic        train_valid,
  input  logic [5:0]  train_index,
  input  logic        train_agree
);
  logic [1:0] counters [0:63];
  logic [5:0] lookup_index;
  logic pending_valid_q;
  logic [5:0] pending_index_q;
  logic pending_agree_q;

  assign lookup_index = lookup_pc[7:2] ^ lookup_pc[13:8];
  assign predicted_taken = lookup_bias ^ !counters[lookup_index][1];

  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 64; i++) counters[i] <= 2'b10;
      pending_valid_q <= 1'b0;
      pending_index_q <= 6'b0;
      pending_agree_q <= 1'b0;
    end else begin
      if (pending_valid_q) begin
        if (pending_agree_q) begin
          if (counters[pending_index_q] != 2'b11)
            counters[pending_index_q] <= counters[pending_index_q] + 2'b01;
        end else begin
          if (counters[pending_index_q] != 2'b00)
            counters[pending_index_q] <= counters[pending_index_q] - 2'b01;
        end
      end
      pending_valid_q <= train_valid;
      if (train_valid) begin
        pending_index_q <= train_index;
        pending_agree_q <= train_agree;
      end
    end
  end
endmodule
