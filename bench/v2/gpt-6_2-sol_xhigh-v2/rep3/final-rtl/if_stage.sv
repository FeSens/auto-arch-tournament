// Four fetch slots. Each contains a bus word followed by up to four
// replay words. Exact validation runs in parallel with bus-word decode.
module if_stage (
  input  logic           clock,
  input  logic           reset,
  input  logic           issue_enable,
  input  logic           repair,
  input  pc_pair_t       repair_pc,
  input  logic           fence_i,
  input  replay_update_t update,
  output logic [31:0]    imem_addr,
  input  logic [31:0]    imem_data,
  input  logic           imem_ready,
  output if_id_t         out
);

  logic [31:2] fallthrough_q, cursor, request_pc, request_next;
  logic [19:2] resume_q;
  logic retry_q, in_window;
  logic [6:2] fetch_index, update_index, write_index;

  // The asynchronous reads feed registers on the same edge as a table
  // write. Both fetch lookups therefore see the same pre-edge entry.
  logic [31:0] valid_q;
  (* syn_ramstyle = "distributed_ram" *) logic [5:0] forecast [0:31];
  (* syn_ramstyle = "distributed_ram" *) logic [19:7] full_tag [0:31];
  (* syn_ramstyle = "distributed_ram" *) logic [31:0] source_instr [0:31];
  (* syn_ramstyle = "distributed_ram" *) logic [19:2] target [0:31];
  (* syn_ramstyle = "distributed_ram" *) logic [19:2] resume_pc [0:31];
  (* syn_ramstyle = "distributed_ram" *) logic [3:0] last_lane [0:31];

  logic matching_update, pending_row, pending_install, stage_prefix;
  logic install_q, write_counter_q, install, write_counter;
  logic [19:2] write_pc_q;
  logic [31:0] write_source_q;
  logic [19:2] write_target_q, write_resume_q;
  logic [3:0] write_last_q;
  logic [127:0] write_words_q;
  logic [1:0] write_direction_q;
  logic [1:0] counter, next_counter;

  assign update_index = update.source_pc[6:2];
  assign write_index = write_pc_q[6:2];
  assign pending_row = update_index == write_index;
  assign pending_install = install_q && pending_row;
  assign matching_update = pending_install
                         ? write_pc_q[19:7] == update.source_pc[19:7]
                           && write_source_q == update.source_instr
                         : valid_q[update_index] && full_tag[update_index] == update.source_pc[19:7]
                           && source_instr[update_index] == update.source_instr;
  assign stage_prefix = update.valid && (|update.last);
  assign install = install_q && !reset && !fence_i;
  assign write_counter = write_counter_q && !reset && !fence_i;
  assign counter = write_counter_q && pending_row ? write_direction_q : forecast[update_index][1:0];

  always_comb begin
    if (update.source_instr[2])
      next_counter = 2'b11;  // JAL
    else if (!matching_update)
      next_counter = 2'b10;
    else if (update.taken)
      next_counter = {counter[1] || counter[0], counter[1] || !counter[0]};
    else
      next_counter = {counter[1] && counter[0], counter[1] && !counter[0]};
  end

  // Register the match and saturating update before writing the payload.
  // Back-to-back updates to one row use the result of the pending write.
  always_ff @(posedge clock) begin
    if (reset || fence_i) begin
      install_q <= 1'b0;
      write_counter_q <= 1'b0;
    end else begin
      install_q <= stage_prefix;
      write_counter_q <= stage_prefix || (update.valid && matching_update);
    end

    write_pc_q <= update.source_pc;
    write_direction_q <= next_counter;
    if (stage_prefix) begin
      write_source_q <= update.source_instr;
      write_target_q <= update.target;
      write_resume_q <= update.resume;
      write_last_q <= update.last;
      write_words_q <= update.words;
    end
  end

  always_ff @(posedge clock) begin
    if (reset || fence_i) valid_q <= '0;
    else if (install) valid_q[write_index] <= 1'b1;

    if (write_counter) forecast[write_index] <= {write_pc_q[10:7], write_direction_q};
    if (install) begin
      full_tag[write_index] <= write_pc_q[19:7];
      source_instr[write_index] <= write_source_q;
      target[write_index] <= write_target_q;
      resume_pc[write_index] <= write_resume_q;
      last_lane[write_index] <= write_last_q;
    end
  end

  logic [4:0] occupancy_q;
  logic [1:0] head_q, tail_q, write_slot, next_head;
  logic [4:0] lane_q;
  logic response, push, issue, pop;
  logic [31:0] issue_word_q;
  pair_decode_t issue_pair_q, bus_pair, next_replay_pair;
  // Give the formal frontend explicit cells for the shallow FIFO lanes.
  // Gowin maps the same four-word arrays to distributed RAM.
  (* mem2reg, syn_ramstyle = "distributed_ram" *) logic [33:0] bus_words [0:3];
  (* mem2reg, syn_ramstyle = "distributed_ram" *) logic [59:0] bus_pc [0:3];
  (* mem2reg, syn_ramstyle = "distributed_ram" *) logic [19:2] replay_target [0:3];
  logic [3:0] synthetic_q;
  logic issue_synthetic_q;
  pc_pair_t head_bus_pc;
  logic [19:2] replay_pc_q, replay_next;
  logic [3:0] slot_last [0:3];
  logic [3:0] head_last;

  logic guess_q, checked_hit, head_guess, reject, predicted_taken;
  logic [1:0] checked_slot_q;
  logic [3:0] checked_last_q;
  logic [19:7] checked_tag_q, response_tag_q;
  logic [31:0] checked_source_q, response_word_q;
  logic [5:1] fetch_forecast;

  assign cursor = guess_q ? {12'b0, resume_q} : fallthrough_q;
  assign request_pc = repair ? repair_pc.addr : cursor;
  assign request_next = repair ? repair_pc.addr_plus_four : cursor + 30'd1;
  assign in_window = request_pc[31:20] == 12'b0;
  assign imem_addr = in_window ? {request_pc, 2'b00} : 32'b0;
  assign response = imem_ready && (repair || !occupancy_q[4]);
  assign push = response && !reject;
  assign write_slot = repair ? 2'd0 : tail_q;
  assign next_head = head_q + 2'd1;

  assign fetch_index = cursor[6:2];
  assign fetch_forecast = forecast[fetch_index][5:1];
  always_ff @(posedge clock) begin
    if (reset) begin
      fallthrough_q <= '0;
      guess_q <= 1'b0;
      retry_q <= 1'b0;
    end else begin
      // On rejection fallthrough_q still holds the accepted source's PC+4.
      if (!reject) fallthrough_q <= response ? request_next : request_pc;
      guess_q <= push && !repair && !retry_q && in_window && valid_q[fetch_index]
              && fetch_forecast[1] && fetch_forecast[5:2] == cursor[10:7]
              && (imem_data[6:0] == 7'h63 || imem_data[6:0] == 7'h6f);
      if (repair || push) retry_q <= repair && !response;
    end

    resume_q <= resume_pc[fetch_index];
    checked_slot_q <= tail_q;
    checked_last_q <= last_lane[fetch_index];
    checked_tag_q <= full_tag[fetch_index];
    checked_source_q <= source_instr[fetch_index];
    response_tag_q <= cursor[19:7];
    response_word_q <= imem_data;
  end

  // The early decision already checked the window and the array index.
  // The stored tag supplies every remaining PC bit in the window.
  assign checked_hit = guess_q && checked_tag_q == response_tag_q
                     && checked_source_q == response_word_q;
  assign reject = guess_q && !checked_hit && !repair;
  assign head_guess = guess_q && checked_slot_q == head_q;

  function automatic pair_decode_t decode_pair(
    input logic [11:0] displacement,
    input logic [2:0] funct3,
    input logic [6:0] opcode
  );
    pair_decode_t pair_kind;
    pair_kind.short_load = opcode == 7'h03 && (funct3[1:0] < 2'd2 || funct3 == 3'd2)
                        && displacement[11:2] == 10'b0 && displacement[1:0] != 2'b11;
    pair_kind.equality_branch = opcode == 7'h63 && funct3[2:1] == 2'b00;
    decode_pair = pair_kind;
  endfunction

  assign bus_pair = decode_pair(imem_data[31:20], imem_data[14:12], imem_data[6:0]);
  always_ff @(posedge clock) begin
    if (response) begin
      bus_words[write_slot] <= {bus_pair, imem_data};
      bus_pc[write_slot] <= {request_pc, request_next};
      replay_target[write_slot] <= target[fetch_index];
      synthetic_q[write_slot] <= !in_window;
    end
  end

  for (genvar slot = 0; slot < 4; slot++) begin : gen_slot
    always_ff @(posedge clock) begin
      // Only the lane mask changes on validation. A rejected younger
      // response can overwrite an empty slot without claiming a credit.
      if (push && write_slot == 2'(slot)) slot_last[slot] <= '0;
      else if (!repair && checked_hit && checked_slot_q == 2'(slot))
        slot_last[slot] <= checked_last_q;
    end
  end

  logic [33:0] head_replay_word [0:3];
  for (genvar lane = 0; lane < 4; lane++) begin : gen_replay_lane
    (* syn_ramstyle = "distributed_ram" *) logic [33:0] words [0:31];
    (* mem2reg, syn_ramstyle = "distributed_ram" *) logic [33:0] slot_word [0:3];
    logic [31:0] install_word;
    pair_decode_t install_pair;
    assign install_word = write_words_q[32*lane +: 32];
    assign install_pair = decode_pair(install_word[31:20], install_word[14:12], install_word[6:0]);

    always_ff @(posedge clock) begin
      if (install) words[write_index] <= {install_pair, install_word};
      if (response) slot_word[write_slot] <= words[fetch_index];
    end

    assign head_replay_word[lane] = slot_word[head_q];
  end

  assign head_bus_pc = bus_pc[head_q];
  assign head_last = slot_last[head_q];
  assign predicted_taken = (head_guess && checked_hit) || (|head_last);
  assign out.valid = !occupancy_q[0];
  assign out.predicted_taken = lane_q[0] && predicted_taken;
  assign out.instr = issue_word_q;
  assign out.pair_decode = issue_synthetic_q ? '0 : issue_pair_q;
  assign out.synthetic = issue_synthetic_q;
  assign replay_next = replay_pc_q + 18'd1;
  assign out.pc = lane_q[0] ? head_bus_pc : {12'b0, replay_pc_q, 12'b0, replay_next};
  assign issue = issue_enable && out.valid;
  assign pop = issue && ((lane_q[0] && !predicted_taken) || (|(lane_q[4:1] & head_last)));

  // Mirror the next issue word at the edge that selects its lane. An
  // empty FIFO bypasses the slot read on acceptance, including repair.
  // The slot still owns the bus PC, replay data and validation result.
  logic use_response, use_queued_bus, use_replay, payload_last, capture_issue_word;
  logic [31:0] next_replay_word;
  // If the head is a fresh guess, it is the only queued slot. A miss
  // issues its bus word and rejects the incoming response, leaving this
  // mirror invalid. The wide payload mux can use the early guess.
  assign payload_last = (lane_q[0] && !head_guess && !(|head_last)) || (|(lane_q[4:1] & head_last));
  assign use_response = repair || occupancy_q[0] || (payload_last && occupancy_q[1]);
  assign use_queued_bus = !use_response && payload_last;
  assign use_replay = !use_response && !payload_last;
  assign capture_issue_word = (repair || occupancy_q[0]) ? response
                            : issue && (!payload_last || !occupancy_q[1] || response);
  assign {next_replay_pair, next_replay_word} =
                            ({34{lane_q[0]}} & head_replay_word[0])
                          | ({34{lane_q[1]}} & head_replay_word[1])
                          | ({34{lane_q[2]}} & head_replay_word[2])
                          | ({34{lane_q[3]}} & head_replay_word[3]);
  always_ff @(posedge clock) begin
    if (capture_issue_word) begin
      {issue_pair_q, issue_word_q} <= ({34{use_response}} & {bus_pair, imem_data})
                                  | ({34{use_queued_bus}} & bus_words[next_head])
                                  | ({34{use_replay}} & {next_replay_pair, next_replay_word});
      issue_synthetic_q <= (use_response && !in_window)
                        || (use_queued_bus && synthetic_q[next_head]);
    end
  end

  always_ff @(posedge clock) begin
    if (reset || repair) begin
      head_q <= 2'd0;
      tail_q <= (!reset && push) ? 2'd1 : 2'd0;
      occupancy_q <= (!reset && push) ? 5'b00010 : 5'b00001;
      lane_q <= 5'b00001;
    end else begin
      case ({push, pop})
        2'b10: occupancy_q <= {occupancy_q[3:0], 1'b0};
        2'b01: occupancy_q <= {1'b0, occupancy_q[4:1]};
        default: ;
      endcase
      if (push) tail_q <= tail_q + 2'd1;
      if (pop) head_q <= next_head;
      if (issue) lane_q <= pop ? 5'b00001 : {lane_q[3:0], 1'b0};
    end

    if (issue) replay_pc_q <= lane_q[0] ? replay_target[head_q] : replay_next;
  end

endmodule
