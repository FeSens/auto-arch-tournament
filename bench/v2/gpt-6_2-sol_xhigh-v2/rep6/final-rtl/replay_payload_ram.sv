// Keep the instruction and steering read interfaces independent.
(* syn_hier = "hard" *) module replay_payload_ram (
  input  logic        clock,
  input  logic        write_en,
  input  logic [7:0]  write_index,
  input  logic [31:2] write_instr,
  input  logic [7:0]  read_index,
  output logic [31:2] read_instr
);

  (* syn_ramstyle = "block_ram" *) logic [31:2] instructions [0:255];

  always_ff @(posedge clock) begin
    if (write_en)
      instructions[write_index] <= write_instr;
    read_instr <= instructions[read_index];
  end

endmodule
