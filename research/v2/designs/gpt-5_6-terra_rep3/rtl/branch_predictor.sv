// rtl/branch_predictor.sv
//
// Fetch-stage successor selector. Every instruction advances sequentially;
// conditional branches and aligned direct JALs redirect from ID, while JALR
// and all unresolved or misaligned control flow recover in EX. Keeping this
// logic to a single increment removes J-immediate extraction and the
// PC-relative target adder from the fetch-to-PC feedback loop.
module branch_predictor (
  input  logic [31:0] lookup_pc,
  output logic [31:0] predicted_next_pc
);

  always_comb begin
    predicted_next_pc = lookup_pc + 32'd4;
  end

endmodule
