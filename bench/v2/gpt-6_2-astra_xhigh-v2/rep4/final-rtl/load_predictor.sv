// One resident 4 KiB page. The two synchronous probes share byte writes.
// A snapshot can lose eligibility while its pipeline stage is held.
module load_predictor (
  input  logic        clock, reset,
  input  logic        collect, execute,
  input  logic [11:2] guess,
  input  logic [31:2] exact_addr,
  output logic [31:0] candidate,
  output logic [31:0] early_word, retry_word,
  output logic        early_hit, retry_hit,

  // A reference is an architecturally completed, aligned RAM access.
  // A nonzero mask installs an accepted bus word or a completed store.
  input  logic        reference,
  input  logic [19:2] ref_addr,
  input  logic [3:0]  ref_mask,
  input  logic [31:0] ref_data
);
  logic page_live;
  logic [19:12] page, challenger;
  logic [4:0] streak;
  wire same_page = page_live && ref_addr[19:12] == page;
  wire replace_page = reference && (!page_live ||
                      (!same_page && challenger == ref_addr[19:12] && (&streak)));

  always_ff @(posedge clock) begin
    if (reset) begin
      page_live <= 1'b0;
      streak <= '0;
    end else if (reference) begin
      challenger <= ref_addr[19:12];
      if (replace_page) begin
        page_live <= 1'b1;
        page <= ref_addr[19:12];
      end
      if (same_page || replace_page)            streak <= '0;
      else if (challenger == ref_addr[19:12])   streak <= streak + 1'b1;
      else                                      streak <= 5'd1;
    end
  end

  logic [3:0] wr_mask;
  logic [11:2] wr_index;
  logic [31:0] wr_data;
  always_ff @(posedge clock) begin
    wr_mask <= (!reset && reference && (same_page || replace_page)) ? ref_mask : 4'b0;
    wr_index <= ref_addr[11:2];
    wr_data <= ref_data;
  end

  logic [31:0] words [0:1023];
  for (genvar lane = 0; lane < 4; lane++) begin : g_write
    always_ff @(posedge clock)
      if (wr_mask[lane])
        words[wr_index][8*lane +: 8] <= wr_data[8*lane +: 8];
  end
  always_ff @(posedge clock) begin
    if (collect) candidate <= words[guess];
    if (execute) begin
      early_word <= candidate;
      retry_word <= words[exact_addr[11:2]];
    end
  end

  // Lazy reset of each sector's eight-bit mask. Partial stores only
  // change enabled bytes and cannot make an unknown word readable.
  logic [127:0] sector_live, sector_full;
  logic [7:0] known [0:127];
  wire [7:0] next_known = (sector_live[wr_index[11:5]] ? known[wr_index[11:5]] : 8'b0) |
                          (8'b1 << wr_index[4:2]);
  always_ff @(posedge clock) begin
    if (&wr_mask) known[wr_index[11:5]] <= next_known;
    if (reset || replace_page) begin
      sector_live <= '0;
      sector_full <= '0;
    end else if (&wr_mask) begin
      sector_live[wr_index[11:5]] <= 1'b1;
      sector_full[wr_index[11:5]] <= &next_known;
    end
  end

  logic [11:2] guess_q, lookup_wr_index;
  logic [7:0] guess_known;
  logic [7:0] written_known;
  logic lookup_write, lookup_full_write, guess_live;
  wire writing = |wr_mask;
  wire clobber_guess = writing && wr_index == guess_q;
  wire first_in_sector = (&wr_mask) && !sector_live[wr_index[11:5]];
  wire clobber_exact = writing && wr_index == exact_addr[11:2];
  wire exact_page = page_live && exact_addr[31:12] == {12'b0, page};
  // Capture conflicts with a logically completed older write before the
  // load reaches MEM. This keeps the MEM hit and repair controls registered.
  wire new_write = reference && (|ref_mask) && same_page;
  wire new_clobber = new_write && ref_addr[11:2] == exact_addr[11:2];
  wire mask_collision = lookup_full_write && lookup_wr_index[11:5] == guess_q[11:5];
  wire [7:0] word_mask = mask_collision ? written_known : guess_known;

  always_ff @(posedge clock) begin
    if (collect) begin
      guess_q <= guess;
      guess_known <= known[guess[11:5]];
      lookup_write <= writing;
      lookup_full_write <= &wr_mask;
      lookup_wr_index <= wr_index;
      written_known <= next_known;
    end
    if (reset || replace_page) guess_live <= 1'b0;
    else if (collect) guess_live <= 1'b1;
    // The lookup-edge mask has write-through above. If a dead sector
    // becomes live after that snapshot, discard it even for a different
    // word: its mask may belong to the previous page.
    else if (clobber_guess || (first_in_sector && wr_index[11:5] == guess_q[11:5]))
      guess_live <= 1'b0;

    if (reset || replace_page) begin
      early_hit <= 1'b0;
      retry_hit <= 1'b0;
    end else if (execute) begin
      early_hit <= exact_page && guess_live && sector_live[guess_q[11:5]] &&
                   word_mask[guess_q[4:2]] && guess_q == exact_addr[11:2] &&
                   !(lookup_write && lookup_wr_index == guess_q) && !clobber_guess && !new_clobber;
      retry_hit <= exact_page && sector_full[exact_addr[11:5]] && !clobber_exact && !new_clobber;
    end
  end
endmodule
