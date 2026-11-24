// Two parity banks read the normal fetch PC and its sequential successor.
// Each bank samples instruction and steering data at the same edge.
module replay_table (
  input  logic           clock,
  input  logic           reset,
  input  logic           invalidate,
  input  replay_update_t update,
  input  logic [31:2]    normal_pc,
  output logic           hit,
  output logic [31:2]    instr,
  output replay_steering_t steering
);

  typedef struct packed {
    logic [31:11] tag;
    logic [11:2] target_word;
  } steering_address_t;

  steering_address_t write_address, even_address_q, odd_address_q;
  localparam integer ADDRESS_WIDTH = $bits(write_address);
  (* syn_ramstyle = "block_ram" *) logic [ADDRESS_WIDTH-1:0] even_address [0:255];
  (* syn_ramstyle = "block_ram" *) logic [ADDRESS_WIDTH-1:0] odd_address [0:255];
  (* syn_ramstyle = "distributed_ram" *) logic [2:0] even_flags [0:255];
  (* syn_ramstyle = "distributed_ram" *) logic [2:0] odd_flags [0:255];
  logic [2:0] write_flags, even_flags_q, odd_flags_q;
  logic [31:2] even_instr_q, odd_instr_q;
  logic [255:0] even_valid_q, odd_valid_q;
  logic even_available_q, odd_available_q;
  logic [7:0] even_index_q, odd_index_q;
  logic [7:0] even_index, odd_index, write_index;
  logic clear, write_even, write_odd, even_hit, odd_hit;

  // The odd word is in the current pair. The even word is in the next
  // pair only when the current PC is odd. These inputs use only flops.
  assign odd_index = normal_pc[10:3];
  assign even_index[0] = normal_pc[3] ^ normal_pc[2];
  for (genvar bit_index = 1; bit_index < 8; bit_index++) begin : g_even_index
    assign even_index[bit_index] = normal_pc[3 + bit_index] ^ (&normal_pc[2 +: bit_index + 1]);
  end
  assign write_index = update.pc[10:3];
  assign write_address = {update.pc[31:11], update.target_word};
  assign write_flags = {update.instr[31], update.branch, update.jal};
  assign clear = reset || invalidate;
  assign write_even = update.valid && !update.pc[2] && !clear;
  assign write_odd  = update.valid &&  update.pc[2] && !clear;

  replay_payload_ram u_even_instr (
    .clock       (clock),
    .write_en    (write_even),
    .write_index (write_index),
    .write_instr (update.instr),
    .read_index  (even_index),
    .read_instr  (even_instr_q)
  );

  replay_payload_ram u_odd_instr (
    .clock       (clock),
    .write_en    (write_odd),
    .write_index (write_index),
    .write_instr (update.instr),
    .read_index  (odd_index),
    .read_instr  (odd_instr_q)
  );

  always_ff @(posedge clock) begin
    if (write_even) begin
      even_address[write_index]  <= write_address;
      even_flags[write_index]    <= write_flags;
    end
    if (write_odd) begin
      odd_address[write_index]  <= write_address;
      odd_flags[write_index]    <= write_flags;
    end
    even_address_q  <= even_address[even_index];
    odd_address_q   <= odd_address[odd_index];
    even_flags_q    <= even_flags[even_index];
    odd_flags_q     <= odd_flags[odd_index];
    even_index_q    <= even_index;
    odd_index_q     <= odd_index;
  end

  // The two validity maps share the write-row decoder.
  for (genvar row = 0; row < 256; row++) begin : g_valid
    logic write_row;
    assign write_row = write_index == 8'(row);
    always_ff @(posedge clock) begin
      if (clear) begin
        even_valid_q[row] <= 1'b0;
        odd_valid_q[row]  <= 1'b0;
      end else begin
        if (write_even && write_row)
          even_valid_q[row] <= 1'b1;
        if (write_odd && write_row)
          odd_valid_q[row] <= 1'b1;
      end
    end
  end

  // Mask same-edge reads and writes to the same bank row. The lane RAMs
  // need no reset or read-during-write behavior of their own.
  always_ff @(posedge clock) begin
    if (clear) begin
      even_available_q <= 1'b0;
      odd_available_q  <= 1'b0;
    end else begin
      even_available_q <= even_valid_q[even_index] && !(write_even && write_index == even_index);
      odd_available_q  <= odd_valid_q[odd_index] && !(write_odd && write_index == odd_index);
    end
  end

  // Compare the sampled row and bank parity in parallel with the high tag.
  // Two-bit tag groups keep the high comparison in parallel LUTs.
  (* syn_keep = 1 *) logic [10:0] even_tag_match, odd_tag_match;
  for (genvar group = 0; group < 10; group++) begin : g_tag
    localparam integer BASE = 11 + 2*group;
    assign even_tag_match[group] = even_address_q.tag[BASE +: 2] == normal_pc[BASE +: 2];
    assign odd_tag_match[group]  = odd_address_q.tag[BASE +: 2]  == normal_pc[BASE +: 2];
  end
  assign even_tag_match[10] = even_address_q.tag[31] == normal_pc[31];
  assign odd_tag_match[10]  = odd_address_q.tag[31]  == normal_pc[31];

  (* syn_keep = 1 *) logic [3:0] even_row_match, odd_row_match;
  for (genvar group = 0; group < 4; group++) begin : g_row
    assign even_row_match[group] = even_index_q[2*group +: 2] == normal_pc[3 + 2*group +: 2];
    assign odd_row_match[group]  = odd_index_q[2*group +: 2]  == normal_pc[3 + 2*group +: 2];
  end
  assign even_hit = even_available_q && !normal_pc[2] && (&even_row_match) && (&even_tag_match);
  assign odd_hit  = odd_available_q  &&  normal_pc[2] && (&odd_row_match)  && (&odd_tag_match);
  assign hit      = even_hit || odd_hit;
  assign instr    = normal_pc[2] ? odd_instr_q : even_instr_q;
  assign steering = normal_pc[2] ? {odd_address_q.target_word, odd_flags_q}
                                 : {even_address_q.target_word, even_flags_q};

endmodule
