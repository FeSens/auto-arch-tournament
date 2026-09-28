// Sixteen tagged exceptions to the static displacement-sign branch bias.
// Counter 11 is invalid; allocation at 10 still predicts the static bias.
module branch_predictor (
  input  logic       clock,
  input  logic       reset,
  input  logic [3:0] lookup_index,
  input  logic [5:0] lookup_tag,
  output logic       agree_msb,
  input  logic       train_valid,
  input  logic [3:0] train_index,
  input  logic [5:0] train_tag,
  input  logic       train_agree
);
  logic       event_valid_q;
  logic [3:0] event_index_q;
  logic [5:0] event_tag_q;
  logic       event_agree_q;
  logic [1:0] counters [0:15];
  logic [5:0] tags [0:15];
  logic [15:0] inverse_hits;

  // Capture validity on every clock, including holds and recovery. A
  // queued event belongs to a branch that already advanced and must drain
  // even when the next EX instruction is held. Reset cancels that event.
  always_ff @(posedge clock) begin
    if (reset) begin
      event_valid_q <= 1'b0;
      event_index_q <= 4'b0;
      event_tag_q <= 6'b0;
      event_agree_q <= 1'b0;
    end else begin
      event_valid_q <= train_valid;
      event_index_q <= train_index;
      event_tag_q <= train_tag;
      event_agree_q <= train_agree;
    end
  end

  for (genvar entry = 0; entry < 16; entry++) begin : g_entry
    localparam logic [3:0] ENTRY_INDEX = 4'(entry);
    // Invalid 11 cannot invert: lookup needs only the counter MSB, with
    // constant-index comparisons instead of a full-word tag/counter mux.
    assign inverse_hits[entry] = (lookup_index == ENTRY_INDEX) &&
                                (lookup_tag == tags[entry]) && !counters[entry][1];
    always_ff @(posedge clock) begin
      if (reset) begin
        counters[entry] <= 2'b11;
        tags[entry] <= 6'b0;
      end else if (event_valid_q && event_index_q == ENTRY_INDEX) begin
        if (counters[entry] != 2'b11 && tags[entry] == event_tag_q) begin
          // Each queued owner event consumes the newest local state.
          // An agreement reaching 11 deallocates this exception.
          if (event_agree_q)
            counters[entry] <= counters[entry] + 2'b01;
          else if (counters[entry] != 2'b00)
            counters[entry] <= counters[entry] - 2'b01;
        end else if (!event_agree_q) begin
          tags[entry] <= event_tag_q;
          counters[entry] <= 2'b10;
        end
        // An agreeing miss cannot disturb another branch's exception.
      end
    end
  end

  // No training bypass: acceptance on an update edge samples the old MSB.
  assign agree_msb = ~(|inverse_hits);
endmodule
