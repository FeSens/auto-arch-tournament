// Synchronous instruction replay. The RAM follows its own stored links.
// The architectural PC independently qualifies every response at issue.
module if_stage (
  input  logic        clock,
  input  logic        reset,
  input  logic        stall,
  input  logic        redirect,
  input  logic [31:0] redirect_target,
  input  btb_update_t update,
  output logic [31:0] imem_addr,
  input  logic [31:0] imem_data,
  input  logic        imem_ready,
  output if_id_t      out
);
  typedef struct packed {
    logic        control;
    logic [1:0]  counter;
    logic [19:2] successor;
    logic [31:0] instr;
  } replay_word_t;
  typedef struct packed {
    logic [19:13] tag;
    replay_word_t word;
  } row_t;

  // Register the EX training transaction before the RAM write port.
  logic fill_valid, fill_control;
  logic [19:2] fill_pc, fill_target;
  logic [1:0]  fill_counter;
  logic [31:0] fill_instr;
  always_ff @(posedge clock) begin
    fill_valid   <= !reset && !update.invalidate && (update.write || update.successor);
    fill_control <= update.write;
    fill_pc      <= update.pc;
    fill_target  <= update.target;
    fill_counter <= update.counter;
    fill_instr   <= update.instr;
  end

  row_t rows [0:2047];
  wire [19:2] fill_successor = fill_control && fill_counter[1] ?
                               fill_target : fill_pc + 18'd1;
  always_ff @(posedge clock) begin
    if (fill_valid)
      rows[fill_pc[12:2]] <= {fill_pc[19:13], fill_control, fill_counter,
                              fill_successor, fill_instr};
  end

  // Only group_live resets. The first fill in a new group replaces the
  // entire initialized mask, including after FENCE.I.
  logic [127:0] group_live;
  logic [15:0] initialized [0:127];
  wire [6:0] fill_group = fill_pc[12:6];
  always_ff @(posedge clock) begin
    if (reset || update.invalidate) group_live <= '0;
    else if (fill_valid)            group_live[fill_group] <= 1'b1;
    if (fill_valid)
      initialized[fill_group] <= (group_live[fill_group] ? initialized[fill_group] : 16'b0) |
                                 (16'b1 << fill_pc[5:2]);
  end

  typedef enum logic [1:0] {FOLLOW, SEQUENTIAL, RETRY} read_mode_t;
  read_mode_t read_mode;
  logic [31:0] pc;
  logic [12:2] read_index, index_q;
  row_t row_q;
  logic [15:0] mask_q;
  logic live_q, row_hit, buffered;
  always_comb begin
    case (read_mode)
      SEQUENTIAL: read_index = pc[12:2] + 11'd1;
      RETRY:      read_index = pc[12:2];
      default:    read_index = row_q.word.successor[12:2];
    endcase
  end

  // On the first stall the outstanding read still completes. While the
  // current word is buffered, hold that next row and all of its metadata.
  always_ff @(posedge clock) begin
    if (!buffered) begin
      row_q   <= rows[read_index];
      index_q <= read_index;
      mask_q  <= initialized[read_index[12:6]];
    end
    if (reset || redirect || update.invalidate)
      live_q <= 1'b0;
    else if (!buffered)
      live_q <= group_live[read_index[12:6]] &&
                !(fill_valid && read_index == fill_pc[12:2]);
  end
  assign row_hit = live_q && mask_q[index_q[5:2]] &&
                   pc == {12'b0, row_q.tag, index_q, 2'b0};

  replay_word_t buffered_word, word;
  always_ff @(posedge clock) begin
    if (!buffered)
      buffered_word <= row_q.word;
    if (reset || redirect || !stall) buffered <= 1'b0;
    else if (row_hit)                buffered <= 1'b1;
  end
  assign word = buffered ? buffered_word : row_q.word;

  always_ff @(posedge clock) begin
    if (reset || redirect)
      read_mode <= SEQUENTIAL;
    else if (buffered)
      read_mode <= FOLLOW;
    else if (stall)
      read_mode <= RETRY;
    else if (read_mode == RETRY || (read_mode == FOLLOW && !row_hit))
      read_mode <= SEQUENTIAL;
    else
      read_mode <= FOLLOW;
  end

  wire hit = buffered || row_hit;
  wire external_control = imem_data[6:0] == 7'h6f ||
                          (imem_data[6:0] == 7'h67 && imem_data[14:12] == 0) ||
                          (imem_data[6:0] == 7'h63 && imem_data[14:13] != 2'b01);
  prediction_t prediction;
  assign prediction.hit     = hit && word.control;
  assign prediction.counter = word.counter;
  assign prediction.target  = word.successor;
  assign prediction.taken   = prediction.hit && word.counter[1] &&
                              (!imem_ready || external_control);

  // Capture the full EX target alongside the normal next PC. The late
  // target comparison then drives one select flop at the recovery edge.
  logic recovering;
  logic [31:0] recovered_pc, normal_pc;
  always_ff @(posedge clock) begin
    recovering   <= !reset && redirect;
    recovered_pc <= redirect_target;
    if (reset)                 normal_pc <= '0;
    else if (stall)            normal_pc <= pc;
    else if (prediction.taken) normal_pc <= {12'b0, prediction.target, 2'b0};
    else                       normal_pc <= pc + 32'd4;
  end
  assign pc             = recovering ? recovered_pc : normal_pc;
  assign imem_addr      = pc;
  assign out.pc         = pc;
  assign out.instr      = imem_ready ? imem_data : word.instr;
  assign out.valid      = imem_ready || hit;
  assign out.prediction = prediction;
endmodule
