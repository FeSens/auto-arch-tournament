// Stateless backward-taken / forward-not-taken direct-control prediction.
// Word-address arithmetic drops only immediate bits known to be zero when
// prediction is enabled, and wraps naturally at the RV32 address boundary.
module branch_predictor (
  input  logic [31:0] pc,
  input  logic [31:0] instr,
  output logic        predicted_taken,
  output logic [31:0] predicted_target
);
  logic legal_branch, is_jal;
  logic [29:0] offset_word, target_word;

  always_comb begin
    legal_branch = (instr[6:0] == 7'b1100011) &&
                   (instr[14:12] != 3'd2 && instr[14:12] != 3'd3);
    is_jal = (instr[6:0] == 7'b1101111);
    predicted_taken = (pc[1:0] == 2'b00) &&
                      ((legal_branch && instr[31] && !instr[8]) ||
                       (is_jal && !instr[21]));
    offset_word = is_jal
                ? {{12{instr[31]}}, instr[19:12], instr[20], instr[30:22]}
                : {{20{instr[31]}}, instr[7], instr[30:25], instr[11:9]};
    target_word = pc[31:2] + offset_word;
    predicted_target = {target_word, 2'b00};
  end
endmodule
