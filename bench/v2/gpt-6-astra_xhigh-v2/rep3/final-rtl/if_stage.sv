// rtl/if_stage.sv
//
// Elastic instruction fetch with four fixed-head flop entries. The PC
// addresses the next unbuffered instruction, independently of ID holds.
// An empty queue bypasses the raw response without adding issue latency.
//
// Instruction data and fetch availability are independent of redirect.
// ID may decode a discarded fetch; only its valid bit is annulled.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold decode consumption
  input  logic              imem_ready,       // raw fetch is available
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  input  logic              train_valid,
  input  logic [3:0]        train_index,
  input  logic              train_agree,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [15:0] agree_msb_q, agree_lsb_q;
  logic [1:0] train_counter, train_next;
  logic direct_branch, direct_jal, predicted_taken;
  logic [31:0] direct_imm, direct_target;
  if_id_t raw_fetch;
  // Use packed bundle bits: Yosys's frontend misreads unpacked arrays of
  // structs as one struct. Each entry still carries the complete if_id_t.
  (* syn_ramstyle = "registers" *) logic [$bits(raw_fetch)-1:0] queue_q [0:3];
  logic [2:0] count_q;
  logic fetch_accept, pop, push;
  logic [2:0] push_index;

  // Full queues resume fetching the cycle after a pop. Capacity depends
  // only on registered occupancy, with no ID-ready path to fetch enable.
  assign fetch_accept = imem_ready && count_q != 3'd4;
  assign pop = count_q != 3'd0 && !stall;
  assign push = fetch_accept && (count_q != 3'd0 || stall);
  assign push_index = count_q - {2'b0, pop};

  always_ff @(posedge clock) begin
    if (reset || redirect)
      count_q <= 3'd0;
    else begin
      case ({push, pop})
        2'b10: count_q <= count_q + 3'd1;
        2'b01: count_q <= count_q - 3'd1;
        default: ;
      endcase
    end
  end

  // Fixed decode head avoids a circular read-pointer mux or inferred RAM.
  // Push overrides the shift at old_count-pop. Payload writes need no
  // recovery/reset gating: occupancy alone invalidates flushed entries.
  for (genvar i = 0; i < 4; i++) begin : queue_entry
    always_ff @(posedge clock) begin
      if (push && push_index == i[2:0])
        queue_q[i] <= raw_fetch;
      else if (pop) begin
        if (i < 3) queue_q[i] <= queue_q[i+1];
      end
    end
  end

  // Two bitplanes hold sixteen saturating agree counters. Update the
  // current entry, never a saved lookup value. Nonblocking writes leave
  // a simultaneous fetch using the pre-edge state, with no update bypass.
  always_comb begin
    train_counter = {agree_msb_q[train_index], agree_lsb_q[train_index]};
    train_next = train_counter;
    if (train_agree && train_counter != 2'b11)
      train_next = train_counter + 2'b01;
    else if (!train_agree && train_counter != 2'b00)
      train_next = train_counter - 2'b01;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      agree_msb_q <= 16'hffff;
      agree_lsb_q <= 16'h0000;
    end else if (train_valid) begin
      agree_msb_q[train_index] <= train_next[1];
      agree_lsb_q[train_index] <= train_next[0];
    end
  end

  // Raw predecode is independent of readiness, recovery, and ID sources.
  // Backward branches have a taken bias; forward branches have a not-taken
  // bias. JAL is always taken. JALR and reserved branch encodings stay linear.
  // Select the immediate before the single shared PC-relative target adder.
  always_comb begin
    direct_branch = imem_data[6:0] == 7'b1100011 &&
                    (imem_data[14:12] != 3'd2 && imem_data[14:12] != 3'd3);
    direct_jal = imem_data[6:0] == 7'b1101111;
    direct_imm = direct_jal
                 ? {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
                    imem_data[20], imem_data[30:21], 1'b0}
                 : {{19{imem_data[31]}}, imem_data[31], imem_data[7],
                    imem_data[30:25], imem_data[11:8], 1'b0};
    direct_target = pc + direct_imm;
    predicted_taken = (direct_target[1:0] == 2'b00) &&
                      (direct_jal || (direct_branch &&
                       (agree_msb_q[pc[5:2]] == imem_data[31])));
    next_pc = predicted_taken ? direct_target : pc + 32'd4;
  end

  // Recovery on EX advancement overrides younger fetch restrictions,
  // including unavailable imem. An older dmem hold defers recovery in EX.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (fetch_accept) pc <= next_pc;
  end

  assign imem_addr = pc;

  always_comb begin
    raw_fetch.pc    = pc;
    raw_fetch.instr = imem_data;
    raw_fetch.predicted_taken = predicted_taken;
    raw_fetch.valid = imem_ready;
    out = count_q != 3'd0 ? queue_q[0] : raw_fetch;
  end

endmodule
