// Probe both base sources alongside issue. The row is implicit in each RAM
// address, so each replica stores only the page, valid bit and raw data.
module load_predictor (
  input  logic         clock,
  input  logic         reset,
  input  logic         capture,
  input  logic [9:0]   ready_row,
  input  logic [9:0]   pending_row,
  input  logic [31:0]  mem_addr,
  input  logic         mem_read,
  input  logic [3:0]   mem_wen,
  input  logic         mem_ready,
  input  logic [31:0]  mem_rdata,
  input  logic [31:0]  mem_wdata,
  output load_word_t   ready_word,
  output load_word_t   pending_word,
  output logic [9:0]   pending_row_q,
  output logic         ready_eligible,
  output logic         pending_eligible
);
  (* syn_ramstyle = "block_ram" *) logic [40:0] ready_words [0:1023];
  (* syn_ramstyle = "block_ram" *) logic [40:0] pending_words [0:1023];
  logic [10:0] scrub;
  logic [9:0] write_row, write_row_q, ready_row_q;
  logic store, in_ram, update_word, valid_word, update_q, scrub_done_q;
  load_word_t write_word;

  assign store = |mem_wen;
  assign in_ram = mem_addr[31:20] == 0;
  assign update_word = mem_ready && ((mem_read && in_ram) || store);
  assign valid_word = in_ram && (mem_read || (mem_wen == 4'b1111 && mem_addr[1:0] == 0));
  assign write_row = scrub[10] ? mem_addr[11:2] : scrub[9:0];
  assign write_word = {scrub[10] && valid_word, mem_addr[19:12],
                       mem_read ? mem_rdata : mem_wdata};

  always_ff @(posedge clock) begin
    if (!scrub[10] || update_word) begin
      ready_words[write_row] <= write_word;
      pending_words[write_row] <= write_word;
    end
    if (capture) begin
      ready_word <= ready_words[ready_row];
      pending_word <= pending_words[pending_row];
      ready_row_q <= ready_row;
      pending_row_q <= pending_row;
      write_row_q <= mem_addr[11:2];
      update_q <= update_word;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      scrub <= '0;
      scrub_done_q <= 1'b0;
    end else begin
      if (!scrub[10]) scrub <= scrub + 11'd1;
      if (capture) scrub_done_q <= scrub[10];
    end
  end

  // The sampled write may have collided at the read edge. An older store
  // entering MEM after that edge keeps its veto through the accepting cycle.
  assign ready_eligible = scrub_done_q && !(update_q && write_row_q == ready_row_q) &&
                          !(store && mem_addr[11:2] == ready_row_q);
  assign pending_eligible = scrub_done_q && !(update_q && write_row_q == pending_row_q) &&
                            !(store && mem_addr[11:2] == pending_row_q);
endmodule
