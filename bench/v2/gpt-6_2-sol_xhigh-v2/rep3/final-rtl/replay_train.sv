// Learn a target prefix from the ordered EX/MEM-to-WB stream. A slot is
// trained only after it survives stalls and any older repair.
module replay_train (
  input  logic           clock,
  input  logic           reset,
  input  logic           fence_i,
  input  logic           advance,
  input  logic [31:0]    pc,
  input  logic [31:0]    pc_next,
  input  logic [31:0]    instr,
  input  logic           direct,
  input  logic           taken,
  output replay_update_t update
);

  logic collecting_q;
  logic [19:2] source_pc_q, target_q;
  logic [31:0] source_instr_q;
  logic [20:2] expected_q, next_pc, resume;
  logic [3:0] last_q, next_last;
  logic [127:0] words_q, collected_words;
  logic word_in_window, terminates, collect_word, start_prefix, finish_prefix;
  logic not_taken;

  assign word_in_window = pc[31:20] == 12'b0 && pc[1:0] == 2'b0;
  assign not_taken = advance && direct && !taken && word_in_window;
  assign start_prefix = advance && direct && taken && word_in_window
                      && pc_next[31:20] == 12'b0 && pc_next[1:0] == 2'b0;

  always_comb begin
    case (instr[6:0])
      7'h63, 7'h6f, 7'h67, 7'h73, 7'h0f: terminates = 1'b1;
      default: terminates = 1'b0;
    endcase
  end

  assign collect_word = advance && collecting_q && word_in_window && !terminates
                      && pc[20:2] == expected_q;
  assign finish_prefix = advance && collecting_q && (!collect_word || last_q[2]);
  assign next_pc = expected_q + 19'd1;
  assign resume = collect_word ? next_pc : expected_q;
  assign next_last = (last_q == 4'b0000) ? 4'b0001 : {last_q[2:0], 1'b0};

  always_comb begin
    collected_words = words_q;
    for (int lane = 0; lane < 4; lane++) begin
      if (collect_word && next_last[lane]) collected_words[32*lane +: 32] = instr;
    end
  end

  always_ff @(posedge clock) begin
    if (reset || fence_i) collecting_q <= 1'b0;
    else if (start_prefix || finish_prefix) collecting_q <= start_prefix;

    if (start_prefix) begin
      source_pc_q <= pc[19:2];
      source_instr_q <= instr;
      target_q <= pc_next[19:2];
      expected_q <= {1'b0, pc_next[19:2]};
      last_q <= '0;
    end else if (collect_word) begin
      expected_q <= next_pc;
      last_q <= next_last;
    end
    words_q <= collected_words;
  end

  // A not-taken branch can terminate an older prefix. Queue its counter
  // update behind that prefix. The next taken source drains this queue
  // before another prefix can finish.
  logic deferred_valid_q;
  logic [19:2] deferred_pc_q;
  logic [31:0] deferred_instr_q;
  replay_update_t update_q;

  always_ff @(posedge clock) begin
    if (reset || fence_i) begin
      deferred_valid_q <= 1'b0;
      update_q.valid <= 1'b0;
    end else begin
      deferred_valid_q <= not_taken && (finish_prefix || deferred_valid_q);
      update_q.valid <= finish_prefix || deferred_valid_q || not_taken;
    end

    if (not_taken && (finish_prefix || deferred_valid_q)) begin
      deferred_pc_q <= pc[19:2];
      deferred_instr_q <= instr;
    end

    update_q.taken <= finish_prefix;
    update_q.source_pc <= finish_prefix ? source_pc_q : deferred_valid_q ? deferred_pc_q : pc[19:2];
    update_q.source_instr <= finish_prefix ? source_instr_q : deferred_valid_q ? deferred_instr_q : instr;
    update_q.last <= (finish_prefix && !resume[20]) ? (collect_word ? next_last : last_q) : '0;
    if (finish_prefix) begin
      update_q.target <= target_q;
      update_q.resume <= resume[19:2];
      update_q.words <= collected_words;
    end
  end

  assign update = update_q;

endmodule
