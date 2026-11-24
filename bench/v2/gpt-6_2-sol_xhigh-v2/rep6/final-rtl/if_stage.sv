// Instruction fetch, page-local prediction, and a four-entry fall-through queue.
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              decode_accept,
  input  logic              correction,
  input  logic [31:2]       recovery_pc,
  input  logic              invalidate_replay,
  input  predictor_update_t predictor_update,
  input  replay_update_t    replay_update,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  output fetch_hazard_t     hazard,
  output if_id_t            out
);

  logic [19:0] pc_page_q, fetch_page;
  logic [9:0]  pc_word_q, fetch_word;
  logic [19:0] normal_page_plus_one, recovery_page_plus_one;
  logic [9:0]  normal_sequential, recovery_sequential;
  logic        normal_wrap, recovery_wrap;
  logic        fetch_advance, live_valid;
  logic        replay_hit, replay_select, replay_taken, normal_taken;
  logic        bus_target_selected, replay_target_selected;
  logic [9:0]  normal_next_word;
  logic        page_write, word_write;
  logic [19:0] next_page;
  logic [9:0]  next_word;
  logic [31:2] replay_instr;
  replay_steering_t replay_steering;

  assign fetch_page = correction ? recovery_pc[31:12] : pc_page_q;
  assign fetch_word = correction ? recovery_pc[11:2] : pc_word_q;

  // Increment each candidate page ahead of the fetch mux. A sequential wrap
  // selects the incremented page even when the fetch is a recovery address.
  assign normal_page_plus_one   = pc_page_q          + 20'd1;
  assign recovery_page_plus_one = recovery_pc[31:12] + 20'd1;
  assign normal_sequential   = pc_word_q          + 10'd1;
  assign recovery_sequential = recovery_pc[11:2] + 10'd1;
  assign normal_wrap = &pc_word_q;
  assign recovery_wrap = &recovery_pc[11:2];

  logic [63:0] trained_q;
  logic [1:0] direction_counters [0:63];
  logic [5:0] lookup_index_q, next_index;
  logic [1:0] old_counter, next_counter;
  logic direction_trained, direction_taken, branch_direction, replay_direction;

  assign direction_trained = trained_q[lookup_index_q];
  assign direction_taken = direction_counters[lookup_index_q][1];
  assign branch_direction = direction_trained ? direction_taken : imem_data[31];
  assign replay_direction = direction_trained ? direction_taken : replay_steering.cold_taken;
  assign old_counter = direction_counters[predictor_update.index];
  always_comb begin
    if (!trained_q[predictor_update.index])
      next_counter = {predictor_update.taken, !predictor_update.taken};
    else if (predictor_update.taken)
      next_counter = (&old_counter) ? old_counter : old_counter + 2'd1;
    else
      next_counter = (|old_counter) ? old_counter - 2'd1 : old_counter;
  end

  // Only the trained bits need reset. Decode samples the pre-write state at
  // the edge, and the queued update proceeds independently of fetch stalls.
  always_ff @(posedge clock) begin
    if (reset)
      trained_q <= '0;
    else if (predictor_update.valid) begin
      trained_q[predictor_update.index] <= 1'b1;
      direction_counters[predictor_update.index] <= next_counter;
    end
  end

  logic branch_prediction, jal_prediction, predicted_taken;
  logic [9:0] displacement_word;
  logic [10:0] predicted_sum;

  assign branch_prediction = (imem_data[6:0] == 7'b1100011)
                          && (imem_data[14:13] != 2'b01)
                          && !imem_data[8] && branch_direction;
  assign jal_prediction = (imem_data[6:0] == 7'b1101111) && !imem_data[21]
                       && (imem_data[19:12] == {8{imem_data[31]}});

  // Opcode bit 3 distinguishes B and JAL on the adder's input path. The
  // displacement is the unsigned low part plus a signed page contribution.
  // A carry equal to the sign cancels that contribution, keeping the target
  // on the source page even at the ends of the 32-bit address space.
  assign displacement_word = imem_data[3] ? {imem_data[20], imem_data[30:22]}
                                          : {imem_data[7], imem_data[30:25], imem_data[11:9]};
  assign predicted_sum = {1'b0, pc_word_q} + {1'b0, displacement_word};
  assign predicted_taken = (branch_prediction || jal_prediction)
                        && (predicted_sum[10] == imem_data[31]);

  assign replay_taken = replay_steering.jal || (replay_steering.branch && replay_direction);
  // Bus readiness selects the PC data. A replay hit and queue space only
  // qualify the write, keeping the tag comparison off the target data mux.
  assign bus_target_selected = imem_ready && predicted_taken;
  assign replay_target_selected = !imem_ready && replay_taken;
  assign normal_taken = bus_target_selected || replay_target_selected;
  assign normal_next_word = ({10{!normal_taken}} & normal_sequential)
                          | ({10{bus_target_selected}} & predicted_sum[9:0])
                          | ({10{replay_target_selected}} & replay_steering.target_word);

  // A correction can always use the queue's flushed slot. Keep the PC
  // data independent of the normal advance conditions on that edge too.
  assign next_page = !correction ? normal_page_plus_one
                   : (imem_ready && recovery_wrap)
                     ? recovery_page_plus_one : recovery_pc[31:12];
  assign next_word = !correction ? normal_next_word
                   : imem_ready ? recovery_sequential : recovery_pc[11:2];
  assign page_write = correction || (fetch_advance && !normal_taken && normal_wrap);
  assign word_write = correction || fetch_advance;

  // Fold the candidate addresses before selection so a registered PC
  // advance also supplies the direction counter's new lookup index.
  function automatic logic [5:0] direction_index(input logic [1:0] page, input logic [9:0] word);
    direction_index = word[5:0] ^ {page, word[9:6]};
  endfunction

  logic [1:0] sequential_page_low;
  logic [5:0] normal_next_index, recovery_next_index;
  assign sequential_page_low = normal_wrap ? normal_page_plus_one[1:0] : pc_page_q[1:0];
  assign normal_next_index = ({6{!normal_taken}} & direction_index(sequential_page_low, normal_sequential))
                           | ({6{bus_target_selected}} & direction_index(pc_page_q[1:0], predicted_sum[9:0]))
                           | ({6{replay_target_selected}} & direction_index(pc_page_q[1:0], replay_steering.target_word));
  assign recovery_next_index = imem_ready ? direction_index(next_page[1:0], recovery_sequential)
                                          : direction_index(recovery_pc[13:12], recovery_pc[11:2]);
  assign next_index = correction ? recovery_next_index : normal_next_index;

  always_ff @(posedge clock) begin
    if (reset) begin
      pc_page_q <= '0;
      pc_word_q <= '0;
      lookup_index_q <= '0;
    end else begin
      if (page_write)
        pc_page_q <= next_page;
      if (word_write) begin
        pc_word_q <= next_word;
        lookup_index_q <= next_index;
      end
    end
  end

  typedef struct packed {
    logic [31:2] pc;
    logic [31:0] instr;
    logic        predicted_taken;
    logic        aligned_branch;
  } fetch_packet_t;

  fetch_packet_t live_packet, enqueue_packet, rear_packet;
  fetch_packet_t head_q;
  localparam integer PACKET_WIDTH = $bits(live_packet);
  logic [PACKET_WIDTH-1:0] rear_q [0:2];
  // A bit is set for each occupied position from the head onward. The
  // push path selects only between adjacent occupancy states.
  logic [3:0] occupancy_q, occupancy_base, occupancy_on_push;
  logic [2:0] rear_read_q, rear_write_q;
  logic empty, space_available, push, pop, promote, push_rear;

  assign empty = !occupancy_q[0] || correction;
  assign space_available = !occupancy_q[3] || correction;
  assign live_valid = imem_ready;
  assign replay_select = !imem_ready && !correction && replay_hit;
  assign fetch_advance = space_available && (live_valid || replay_select);
  assign push = space_available && (replay_select || (live_valid && (!empty || !decode_accept)));
  assign pop = !empty && decode_accept;
  assign promote = pop && occupancy_q[1];
  assign push_rear = push && !empty && (!pop || promote);
  assign occupancy_base = pop ? (occupancy_q >> 1) : occupancy_q;
  assign occupancy_on_push = pop ? occupancy_q : {occupancy_q[2:0], 1'b1};

  always_ff @(posedge clock) begin
    if (reset) begin
      occupancy_q  <= '0;
      rear_read_q  <= 3'b001;
      rear_write_q <= 3'b001;
    end else if (correction) begin
      occupancy_q  <= {3'b000, push};
      rear_read_q  <= 3'b001;
      rear_write_q <= 3'b001;
    end else begin
      occupancy_q <= occupancy_base | ({4{push}} & occupancy_on_push);

      if (promote)
        rear_read_q <= {rear_read_q[1:0], rear_read_q[2]};
      if (push_rear)
        rear_write_q <= {rear_write_q[1:0], rear_write_q[2]};
    end
  end

  assign imem_addr = {fetch_page, fetch_word, 2'b00};
  logic live_aligned_branch, replay_aligned_branch;
  assign live_aligned_branch = (imem_data[6:0] == 7'b1100011)
                            && (imem_data[14:13] != 2'b01) && !imem_data[8];
  assign replay_aligned_branch = (replay_instr[6:2] == 5'b11000) && !replay_instr[8];
  assign live_packet = {fetch_page, fetch_word, imem_data, !correction && predicted_taken,
                        live_aligned_branch};
  // A replay hit has the normal fetch address. Only the bus falls through
  // to decode. On a stall the lookup payload can drive the queue data;
  // only an exact hit can publish that payload.
  assign enqueue_packet.pc = live_packet.pc;
  assign enqueue_packet.instr = (imem_ready || correction) ? live_packet.instr : {replay_instr, 2'b11};
  assign enqueue_packet.predicted_taken = !correction && normal_taken;
  assign enqueue_packet.aligned_branch = (imem_ready || correction) ? live_packet.aligned_branch : replay_aligned_branch;

  for (genvar slot = 0; slot < 3; slot++) begin : g_rear
    // Only advancing the rear pointer publishes a write to the free slot.
    always_ff @(posedge clock) begin
      if (!occupancy_q[3] && rear_write_q[slot])
        rear_q[slot] <= enqueue_packet;
    end
  end

  always_comb begin
    rear_packet = '0;
    for (int slot = 0; slot < 3; slot++)
      rear_packet |= rear_q[slot] & {PACKET_WIDTH{rear_read_q[slot]}};
  end

  always_ff @(posedge clock) begin
    // Reuse the head on a one-entry pop with a push. With more entries,
    // promotion uses the old rear head regardless of a simultaneous push.
    if (empty || pop)
      head_q <= (empty || !occupancy_q[1]) ? enqueue_packet : rear_packet;
  end

  assign out.pc              = {empty ? live_packet.pc : head_q.pc, 2'b00};
  assign out.instr           = empty ? live_packet.instr : head_q.instr;
  assign out.predicted_taken = empty ? live_packet.predicted_taken : head_q.predicted_taken;
  assign out.valid           = !empty || live_valid;

  // The interlock only looks for dependencies on a valid EX producer.
  // Its input can use the normal queue selection during correction since
  // correction already masks that producer.
  assign hazard = !occupancy_q[0]
                ? {imem_data[19:15], imem_data[24:20], live_aligned_branch}
                : {head_q.instr[19:15], head_q.instr[24:20], head_q.aligned_branch};

  replay_table u_replay (
    .clock      (clock),
    .reset      (reset),
    .invalidate (invalidate_replay),
    .update     (replay_update),
    .normal_pc  ({pc_page_q, pc_word_q}),
    .hit        (replay_hit),
    .instr      (replay_instr),
    .steering   (replay_steering)
  );

endmodule
