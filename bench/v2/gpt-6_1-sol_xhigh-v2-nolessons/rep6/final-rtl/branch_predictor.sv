// Sixteen independent saturating agreement counters. Only their MSBs
// enter the balanced fetch lookup; no target or instruction is stored.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module branch_predictor (
  input  logic       clock,
  input  logic       reset,
  input  logic [3:0] lookup_index,
  output logic       agreement,
  input  predictor_train_t train,
  input  logic       advance
);
  wire [15:0] agreement_bits;
  wire [7:0] lookup_pairs;
  wire [3:0] lookup_quads;
  wire [1:0] lookup_halves;

  for (genvar entry = 0; entry < 16; entry++) begin : g_counters
    localparam logic [3:0] ENTRY_INDEX = 4'(entry);
    logic [1:0] counter_q;
    wire update_entry = advance && train.valid && (train.index == ENTRY_INDEX);
    always_ff @(posedge clock) begin
      if (reset) counter_q <= 2'b11;
      else if (update_entry) begin
        if (train.agree) begin
          if (counter_q != 2'b11) counter_q <= counter_q + 2'b01;
        end else begin
          if (counter_q != 2'b00) counter_q <= counter_q - 2'b01;
        end
      end
    end
    assign agreement_bits[entry] = counter_q[1];
  end
  for (genvar pair = 0; pair < 8; pair++) begin : g_pairs
    assign lookup_pairs[pair] = lookup_index[0] ? agreement_bits[2*pair+1]
                                                       : agreement_bits[2*pair];
  end
  for (genvar quad = 0; quad < 4; quad++) begin : g_quads
    assign lookup_quads[quad] = lookup_index[1] ? lookup_pairs[2*quad+1]
                                                       : lookup_pairs[2*quad];
  end
  for (genvar half = 0; half < 2; half++) begin : g_halves
    assign lookup_halves[half] = lookup_index[2] ? lookup_quads[2*half+1]
                                                        : lookup_quads[2*half];
  end
  assign agreement = lookup_index[3] ? lookup_halves[1] : lookup_halves[0];
endmodule
