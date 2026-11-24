// rtl/if_stage.sv
//
// Instruction fetch with a tagged taken-target predictor, PC-indexed
// instruction replay, and a four-entry fall-through queue. The oldest unissued PC is
// visible even without a response.
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              decode_ready,
  input  logic              recovery_issue_ready,
  input  logic              reject_target,
  input  logic              reject_sequential,
  input  logic [31:2]       sequential_pc,
  input  logic [31:2]       target_pc,
  input  logic              take_target,
  input  logic              train,
  input  logic [31:2]       train_pc,
  input  logic              train_branch,
  output logic              recovering,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  output logic              decode_valid,
  output if_id_t            out
);

  logic [31:2] pc_q, recovery_pc_q, fetch_pc, predicted_pc;
  logic [31:2] fetch_plus4;
  logic [6:0]  pc_index_q, predicted_index;
  logic        reject_target_q, reject_sequential_q, take_target_q;
  logic        mispredict, correction_pending, correction_hold_q, recovery_wait_q;
  logic [8:0]  scrub_index_q;

  function automatic logic [6:0] pc_hash(input logic [15:2] pc);
    pc_hash = pc[8:2] ^ pc[15:9];
  endfunction

  // Valid, conditional, source tag, page-local target word, target hash,
  // and whether fetching the target would read the source's replay row.
  // The hash and source tag together distinguish all aligned source PCs.
  (* syn_ramstyle = "distributed_ram" *) logic [46:0] targets [0:127];
  (* syn_ramstyle = "distributed_ram" *) logic [1:0] direction [0:127];
  (* syn_ramstyle = "distributed_ram" *) logic taken_vote [0:127];
  logic        valid, conditional, select_target, target_same_replay_row;
  logic [31:9] tag, train_tag_q;
  logic [5:0]  tag_match;
  logic [15:2] target_offset;
  logic [6:0]  target_index, train_index_q, predictor_write_index;
  logic [8:0]  train_replay_index_q;
  logic        train_q, train_branch_q, predictor_scrub_q;
  logic        target_write, direction_write, same_page;
  logic [46:0] target_write_data;
  logic [1:0]  counter, counter_next;

  assign mispredict = take_target_q ? reject_target_q : reject_sequential_q;
  assign correction_pending = mispredict || correction_hold_q;
  assign recovering = mispredict || recovery_wait_q;
  assign fetch_pc = correction_pending ? recovery_pc_q : pc_q;
  assign {valid, conditional, tag, target_offset, target_index, target_same_replay_row} = targets[pc_index_q];
  // Compare short tag slices in parallel to keep a wide carry chain
  // between the distributed RAM and the successor mux out of the lookup.
  for (genvar group = 0; group < 5; group++) begin : gen_tag_match
    assign tag_match[group] = &(tag[9 + 4*group +: 4] ~^ pc_q[9 + 4*group +: 4]);
  end
  assign tag_match[5] = &(tag[31:29] ~^ pc_q[31:29]);
  assign select_target = !correction_pending && !predictor_scrub_q && valid && (&tag_match) &&
                         (!conditional || taken_vote[pc_index_q]);
  assign fetch_plus4 = fetch_pc + 30'd1;
  assign predicted_pc = select_target ? {pc_q[31:16], target_offset} : fetch_plus4;
  assign predicted_index = select_target ? target_index : pc_hash(fetch_plus4[15:2]);

  // Reuse the first 128 reset scrub writes. Later replay invalidations
  // leave predictor state available and EX continues to validate it.
  assign predictor_write_index = predictor_scrub_q ? scrub_index_q[6:0] : train_index_q;
  assign target_write = predictor_scrub_q || (train_q && take_target_q);
  assign direction_write = predictor_scrub_q || (train_q && train_branch_q);
  assign same_page = train_tag_q[31:16] == recovery_pc_q[31:16];
  assign target_write_data = predictor_scrub_q ? '0 :
                             {same_page, train_branch_q, train_tag_q,
                              recovery_pc_q[15:2], pc_hash(recovery_pc_q[15:2]),
                              train_replay_index_q == recovery_pc_q[10:2]};
  assign counter = direction[train_index_q];

  always_comb begin
    counter_next = counter;
    if (predictor_scrub_q)
      counter_next = 2'b01;
    else if (take_target_q && counter != 2'b11)
      counter_next = counter + 2'd1;
    else if (!take_target_q && counter != 2'b00)
      counter_next = counter - 2'd1;
  end

  always_ff @(posedge clock) begin
    if (target_write)
      targets[predictor_write_index] <= target_write_data;
    if (direction_write) begin
      direction[predictor_write_index] <= counter_next;
      taken_vote[predictor_write_index] <= counter_next[1];
    end

    if (reset)
      predictor_scrub_q <= 1'b1;
    else if (predictor_scrub_q && (&scrub_index_q[6:0]))
      predictor_scrub_q <= 1'b0;
  end

  logic       fetch_available, fetch_accept, bus_accept;
  logic       empty, full;

  // The read and PC advance together. The remaining bits of the aligned
  // word address distinguish every PC that maps to the same entry.
  typedef struct packed {
    logic        valid;
    logic [31:11] tag;
    logic [31:0]  word;
  } replay_entry_t;

  (* syn_ramstyle = "block_ram" *) logic [53:0] replay [0:511];
  replay_entry_t read_entry_q, write_entry;
  logic [8:0]    write_index;
  logic          read_enable, lookup_valid_q;
  logic          scrub_active, scrub_running_q;
  logic          fill, replay_available;

  assign scrub_active = scrub_running_q || (mispredict && !train_q);
  assign read_enable = fetch_accept && !scrub_active;
  // PC+4 always reads a different row. A taken prediction may read the
  // source row, so accept the bus word and leave that row intact.
  assign fill        = bus_accept && !scrub_active && !(select_target && target_same_replay_row);
  assign write_index = scrub_active ? scrub_index_q : fetch_pc[10:2];
  assign write_entry = scrub_active ? '0 : {1'b1, fetch_pc[31:11], imem_data};

  always_ff @(posedge clock) begin
    if (scrub_active || fill)
      replay[write_index] <= write_entry;
    if (read_enable)
      read_entry_q <= replay[predicted_pc[10:2]];
  end

  assign replay_available = lookup_valid_q && !correction_pending && !reset &&
                            read_entry_q.valid && read_entry_q.tag == pc_q[31:11];

  always_ff @(posedge clock) begin
    scrub_running_q <= reset || (scrub_active && !(&scrub_index_q));

    // The index wraps back to zero on the final write. While a scrub is
    // running, a new redirect can rely on the rows already cleared.
    if (reset)
      scrub_index_q  <= '0;
    else if (scrub_active)
      scrub_index_q <= scrub_index_q + 9'd1;

    // The correction masks the result as soon as the scrub starts.
    if (reset || scrub_active)
      lookup_valid_q <= 1'b0;
    else if (read_enable)
      lookup_valid_q <= 1'b1;
  end

  // The wrap bit distinguishes full from empty at equal RAM indices.
  (* syn_ramstyle = "distributed_ram" *) logic [31:0] queue_words [0:3];
  (* syn_ramstyle = "distributed_ram" *) logic [31:2] queue_pcs [0:3];
  logic [2:0] read_ptr_q, write_ptr_q;
  logic [2:0] next_read_ptr;
  logic       pop, push;
  logic [31:2] head_pc_q;
  logic [31:0] fetch_word;

  // Recovery hides the old queue as soon as the corrected PC is visible.
  assign empty = correction_pending || read_ptr_q == write_ptr_q;
  assign full  = !correction_pending && {~read_ptr_q[2], read_ptr_q[1:0]} == write_ptr_q;
  assign pop   = !empty && decode_ready;
  assign next_read_ptr = read_ptr_q + 3'd1;
  assign bus_accept = !reset && !full && imem_ready;
  assign fetch_available = imem_ready || replay_available;
  assign fetch_accept = !reset && !full && fetch_available;
  assign fetch_word = imem_ready ? imem_data : read_entry_q.word;
  assign push = fetch_accept && !(empty && decode_ready);

  assign imem_addr = {fetch_pc, 2'b00};
  assign decode_valid = !empty || fetch_available;
  assign out.instr = empty ? fetch_word : queue_words[read_ptr_q[1:0]];
  assign out.pc = empty ? imem_addr : {head_pc_q, 2'b00};

  always_ff @(posedge clock) begin
    // Write every accepted word. Bypass leaves both pointers unchanged,
    // and a pop from a full queue frees a slot on the next cycle.
    if (fetch_accept) begin
      queue_pcs[write_ptr_q[1:0]]   <= fetch_pc;
      queue_words[write_ptr_q[1:0]] <= fetch_word;
    end

    // Capture an incoming head when the queue is empty or the last entry
    // pops. Otherwise a pop promotes the next buffered address.
    if (empty || pop)
      head_pc_q <= (empty || next_read_ptr == write_ptr_q) ? fetch_pc
                                                          : queue_pcs[next_read_ptr[1:0]];

    if (reset) begin
      read_ptr_q  <= '0;
      write_ptr_q <= '0;
    end else begin
      // Discard the wrong path at the write pointer so the corrected word
      // can bypass or enqueue through the same port during recovery.
      if (mispredict)
        read_ptr_q <= write_ptr_q;
      else if (pop)
        read_ptr_q <= next_read_ptr;
      if (push)
        write_ptr_q <= write_ptr_q + 3'd1;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      pc_q                <= '0;
      pc_index_q          <= '0;
      correction_hold_q   <= 1'b0;
      recovery_wait_q     <= 1'b0;
      reject_target_q     <= 1'b0;
      reject_sequential_q <= 1'b0;
    end else begin
      if (fetch_accept) begin
        pc_q <= predicted_pc;
        pc_index_q <= predicted_index;
      end
      // Fetch can continue as soon as the target response is buffered.
      // EX remains squashed until decode issues that first instruction.
      correction_hold_q <= correction_pending && !imem_ready;
      // EX is squashed during recovery, so only a dmem hold blocks issue.
      recovery_wait_q <= recovering && !(recovery_issue_ready && decode_valid);
      reject_target_q <= reject_target;
      reject_sequential_q <= reject_sequential;
    end

    // Capture the resolved address independently of EX's comparison.
    // Hold it while the corrected fetch waits, and use it as the staged
    // target when an advancing control transfer was taken.
    if (!recovering)
      recovery_pc_q <= take_target ? target_pc : sequential_pc;
    take_target_q        <= take_target;
    train_tag_q          <= train_pc[31:9];
    train_index_q        <= pc_hash(train_pc[15:2]);
    train_replay_index_q <= train_pc[10:2];
    train_branch_q       <= train_branch;
    train_q              <= !reset && train;
  end

endmodule
