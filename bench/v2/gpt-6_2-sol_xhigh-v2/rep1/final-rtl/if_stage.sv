// rtl/if_stage.sv
//
// Predict the ordinary request and steer corrected requests independently.
// Replay reads alongside the fetch PC register.
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              hold_id,
  input  logic              hold_mem,
  input  fetch_resolution_t fetch_resolution,
  input  btb_training_t     btb_training,
  input  logic              training_taken,
  input  logic [31:0]       candidate_pc,
  output logic              candidate_btb_hit,
  output logic [1:0]        candidate_btb_counter,
  output btb_update_t       btb_update,
  output logic              squash_candidate,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  output logic              fetch_accept,
  output logic [31:0]       ordinary_pc,
  output logic              fetch_parked,
  output if_id_t            out
);

  logic [31:0] pc, normal_pc_q, normal_pc_d;
  logic [31:0] ordinary_plus4, corrected_plus4;
  logic [31:0] target_plus4, fallthrough_plus4;
  logic [31:0] table_target, bypass_target;
  logic        ordinary_accept, corrected_accept, ordinary_in_range, target_in_range, fallthrough_in_range;
  logic        ordinary_available, ordinary_can_accept, ordinary_can_advance;
  logic        ordinary_last, target_last, fallthrough_last, predict_taken, ordinary_park;
  logic        recover_target, recover_fallthrough;
  logic        ordinary_active, target_advance, fallthrough_advance;
  logic        select_held, select_sequential, select_table_target, select_bypass_target;
  logic        select_target, select_target_plus4, select_fallthrough, select_fallthrough_plus4;
  logic [4:0]  ordinary_index, candidate_index, write_index;
  logic [12:0] write_tag;
  logic        ordinary_same_index, ordinary_table_hit, taken_target_bypass;
  logic        ordinary_taken_hit, ordinary_bypass_hit, predict_on_table, predict_on_bypass;
  logic [1:0]  taken_counter, not_taken_counter, ordinary_counter;
  btb_action_t selected_action;

  logic [31:0] btb_valid;
  logic [30:0] btb_entry [0:31]; // {tag, word target}
  logic [1:0]  btb_counter [0:31];
  logic [12:0] ordinary_tag, candidate_tag;
  logic [17:0] ordinary_table_target;

  logic          replay_armed_q;
  logic [31:0]   replay_bank_valid_q;
  logic [31:0]   replay_valid_slots [0:31];
  logic [31:0]   replay_read_slots_q, replay_update_slots_q, replay_last_slots_q;
  logic [31:0]   replay_slots_update, replay_slots_write;
  logic [4:0]    replay_read_bank, replay_write_bank;
  logic [4:0]    replay_last_bank_q;
  logic          replay_bitmap_write, replay_bitmap_write_q;
  logic [39:0]   replay_entry [0:1023]; // {PC[19:12], instruction}
  logic [7:0]    replay_tag;
  logic [31:0]   replay_word;
  logic          replay_hit, replay_fill, replay_collision, replay_slot_valid, replay_eligible;
  logic          replay_write_q;
  logic [9:0]    replay_write_index_q;

  assign recover_target = fetch_resolution.valid && fetch_resolution.take_target
                       && !fetch_resolution.match_target;
  assign recover_fallthrough = fetch_resolution.valid && !fetch_resolution.take_target
                            && (!fetch_resolution.match_fallthrough || fetch_resolution.refetch);
  assign squash_candidate = recover_target || recover_fallthrough;
  assign ordinary_pc = normal_pc_q;

  assign selected_action = training_taken ? btb_training.taken : btb_training.not_taken;
  assign btb_update.pc_word = btb_training.pc_word;
  assign btb_update.target_word = btb_training.target_word;
  assign btb_update.write_target = selected_action.write_target;
  assign btb_update.write_counter = selected_action.write_counter;
  assign btb_update.counter = selected_action.counter;
  assign {write_tag, write_index} = btb_update.pc_word;

  // Compare both tags in parallel with the pending counter decisions.
  assign ordinary_index = normal_pc_q[6:2];
  assign ordinary_same_index = write_index == ordinary_index;
  assign ordinary_in_range = normal_pc_q[31:20] == 12'b0 && normal_pc_q[1:0] == 2'b00;
  assign {ordinary_tag, ordinary_table_target} = btb_entry[ordinary_index];
  assign ordinary_table_hit = ordinary_in_range && btb_valid[ordinary_index]
                           && !(|(ordinary_tag ^ normal_pc_q[19:7]));
  assign ordinary_bypass_hit = ordinary_in_range && !(|(write_tag ^ normal_pc_q[19:7]));
  assign taken_target_bypass = ordinary_same_index && btb_training.taken.write_target;
  assign ordinary_taken_hit = taken_target_bypass ? ordinary_bypass_hit : ordinary_table_hit;
  assign taken_counter = ordinary_same_index && btb_training.taken.write_counter
                       ? btb_training.taken.counter : btb_counter[ordinary_index];
  assign not_taken_counter = ordinary_same_index && btb_training.not_taken.write_counter
                           ? btb_training.not_taken.counter : btb_counter[ordinary_index];
  assign predict_on_table = ordinary_table_hit
                         && (training_taken ? !taken_target_bypass && taken_counter[1] : not_taken_counter[1]);
  assign predict_on_bypass = ordinary_bypass_hit && training_taken && taken_target_bypass && taken_counter[1];
  assign ordinary_plus4 = normal_pc_q + 32'd4;
  assign ordinary_last = normal_pc_q == 32'h000f_fffc;
  assign ordinary_can_accept = !hold_id && !fetch_parked;
  assign ordinary_available = imem_ready || replay_hit;
  assign ordinary_accept = ordinary_can_accept && ordinary_available;
  assign predict_taken = predict_on_table || predict_on_bypass;
  assign ordinary_park = ordinary_accept ? ordinary_last && !predict_taken : fetch_parked;
  assign ordinary_counter = training_taken ? taken_counter : not_taken_counter;

  // A correction bypasses the ordinary candidate's EX hold and prediction.
  // The two increments run in parallel with resolution of the direction.
  assign corrected_accept = imem_ready && !hold_mem;
  assign target_plus4 = fetch_resolution.target + 32'd4;
  assign fallthrough_plus4 = fetch_resolution.fallthrough + 32'd4;
  assign corrected_plus4 = recover_target ? target_plus4 : fallthrough_plus4;
  assign target_last = fetch_resolution.target == 32'h000f_fffc;
  assign fallthrough_last = fetch_resolution.fallthrough == 32'h000f_fffc;
  assign target_in_range = fetch_resolution.target[31:20] == 12'b0
                        && fetch_resolution.target[1:0] == 2'b00;
  assign fallthrough_in_range = fetch_resolution.fallthrough[31:20] == 12'b0
                             && fetch_resolution.fallthrough[1:0] == 2'b00;
  assign fetch_accept = squash_candidate ? corrected_accept : ordinary_accept;
  assign pc = ({32{!squash_candidate}} & normal_pc_q)
            | ({32{recover_target}} & fetch_resolution.target)
            | ({32{recover_fallthrough}} & fetch_resolution.fallthrough);

  // Corrected fetches proceed sequentially. Their separate metadata
  // lookup runs from the captured PC after the older BTB write commits.
  assign candidate_index = candidate_pc[6:2];
  assign candidate_tag = btb_entry[candidate_index][30:18];
  assign candidate_btb_hit = candidate_pc[31:20] == 12'b0 && candidate_pc[1:0] == 2'b00
                          && btb_valid[candidate_index] && candidate_tag == candidate_pc[19:7];
  assign candidate_btb_counter = btb_counter[candidate_index];

  // Resolve the one-hot enables in parallel with the eight addresses.
  // Reset clears all enables, selecting PC zero for the register and replay reads.
  assign ordinary_active = !reset && !squash_candidate;
  assign ordinary_can_advance = ordinary_active && ordinary_can_accept;
  assign select_held = ordinary_active && (!ordinary_can_accept || !ordinary_available
                                           || (ordinary_last && !predict_taken));
  assign select_sequential = ordinary_available && (ordinary_can_advance && !ordinary_last && !predict_taken);
  assign select_table_target = ordinary_available && (ordinary_can_advance && predict_on_table);
  assign select_bypass_target = ordinary_available && (ordinary_can_advance && predict_on_bypass);

  assign target_advance = corrected_accept && !target_last;
  assign fallthrough_advance = corrected_accept && !fallthrough_last;
  assign select_target = !reset && recover_target && !target_advance;
  assign select_target_plus4 = !reset && recover_target && target_advance;
  assign select_fallthrough = !reset && recover_fallthrough && !fallthrough_advance;
  assign select_fallthrough_plus4 = !reset && recover_fallthrough && fallthrough_advance;

  assign table_target = {12'b0, ordinary_table_target, 2'b00};
  assign bypass_target = {12'b0, btb_training.target_word, 2'b00};
  for (genvar i = 0; i < 32; i++) begin : select_pc_bit
    assign normal_pc_d[i] = |{select_held & normal_pc_q[i],
                              select_sequential & ordinary_plus4[i],
                              select_table_target & table_target[i],
                              select_bypass_target & bypass_target[i],
                              select_target & fetch_resolution.target[i],
                              select_target_plus4 & target_plus4[i],
                              select_fallthrough & fetch_resolution.fallthrough[i],
                              select_fallthrough_plus4 & fallthrough_plus4[i]};
  end
  always_ff @(posedge clock) begin
    normal_pc_q <= normal_pc_d;
    fetch_parked <= !reset && ((!squash_candidate && ordinary_park)
                             || (corrected_accept && ((recover_target && target_last)
                                                       || (recover_fallthrough && fallthrough_last))));
  end

  assign replay_collision = replay_write_q && replay_write_index_q == normal_pc_q[11:2];
  assign replay_read_bank = normal_pc_q[11:7];
  assign replay_write_bank = replay_write_index_q[9:5];
  // Select the slot on both bitmap paths before applying the bank bypass.
  assign replay_slot_valid = replay_bitmap_write_q && replay_last_bank_q == replay_read_bank
                           ? replay_last_slots_q[ordinary_index] : replay_read_slots_q[ordinary_index];
  assign replay_slots_update = replay_bitmap_write_q && replay_last_bank_q == replay_write_bank
                               ? replay_last_slots_q : replay_update_slots_q;
  assign replay_slots_write = (replay_bank_valid_q[replay_write_bank]
                               ? replay_slots_update : 32'b0)
                            | (32'b1 << replay_write_index_q[4:0]);
  assign replay_bitmap_write = !reset && !fetch_resolution.refetch && replay_write_q;
  assign replay_eligible = replay_armed_q && ordinary_in_range && replay_bank_valid_q[replay_read_bank]
                        && replay_tag == normal_pc_q[19:12] && !replay_collision;
  assign replay_hit = replay_eligible && replay_slot_valid;
  // Refresh every accepted bus word while armed, including an existing hit.
  assign replay_fill = !reset && !fetch_resolution.refetch && imem_ready && fetch_accept
                    && ((!squash_candidate && ordinary_in_range) || (recover_target && target_in_range)
                        || (recover_fallthrough && fallthrough_in_range))
                    && (replay_armed_q || recover_target);

  always_ff @(posedge clock) begin
    {replay_tag, replay_word} <= replay_entry[normal_pc_d[11:2]];
    if (replay_fill)
      replay_entry[pc[11:2]] <= {pc[19:12], imem_data};

    // Suppress hits on the sampled read/write collision for any RAM mode.
    replay_write_q <= replay_fill;
    replay_write_index_q <= pc[11:2];

    // The bitmap reads alongside each replay index. Forward its last
    // write to cover same-bank RAM collisions on either read port.
    replay_read_slots_q <= replay_valid_slots[normal_pc_d[11:7]];
    replay_update_slots_q <= replay_valid_slots[pc[11:7]];
    replay_bitmap_write_q <= replay_bitmap_write;
    if (replay_bitmap_write) begin
      replay_last_bank_q <= replay_write_bank;
      replay_last_slots_q <= replay_slots_write;
      replay_valid_slots[replay_write_bank] <= replay_slots_write;
    end

    // Reset the bank flags in one edge. The first write to each bank
    // replaces its stale bitmap. The collision check covers the beat
    // before a newly filled word's bitmap write takes effect.
    if (reset || fetch_resolution.refetch) begin
      replay_bank_valid_q <= '0;
    end else if (replay_bitmap_write) begin
      replay_bank_valid_q[replay_write_bank] <= 1'b1;
    end
  end

  always_ff @(posedge clock) begin
    if (reset || fetch_resolution.refetch)
      replay_armed_q <= 1'b0;
    else if ((!squash_candidate && ordinary_accept && predict_taken) || recover_target)
      replay_armed_q <= 1'b1;
  end

  always_ff @(posedge clock) begin
    if (reset)
      btb_valid <= '0;
    else if (btb_update.write_target)
      btb_valid[write_index] <= 1'b1;

    if (!reset && btb_update.write_target)
      btb_entry[write_index] <= {write_tag, btb_update.target_word};
    if (!reset && btb_update.write_counter)
      btb_counter[write_index] <= btb_update.counter;
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc          = pc;
    out.pc_plus4    = squash_candidate ? corrected_plus4 : ordinary_plus4;
    out.instr       = imem_ready ? imem_data : replay_word;
    out.btb_hit     = training_taken ? ordinary_taken_hit : ordinary_table_hit;
    out.btb_counter = ordinary_counter;
  end

endmodule
