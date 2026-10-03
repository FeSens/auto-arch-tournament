// rtl/if_stage.sv
//
// Fetch PC and two-entry fall-through instruction queue. The empty queue
// bypasses the bus token directly to ID; otherwise only the oldest stored
// token is visible. Fetch acceptance is independent of downstream holds.
//
// Raw instruction bits always reach decode and dependency comparisons.
// Squashes use validity and the ID/EX flush, never an instruction mux.
// Direct targets come from this instruction; the table stores direction
// only, so aliases cannot substitute another instruction's target.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              decode_accept,    // selected head enters ID/EX
  input  logic              redirect,         // advancing EX correction
  input  logic [31:0]       redirect_target,
  input  logic              branch_train,
  input  logic [5:0]        branch_index,
  input  logic              branch_outcome,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [1:0] counters [0:63];
  logic direct_branch, direct_jump, predict_taken;
  logic [31:0] direct_imm, direct_target;
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
    logic        predicted_taken;
  } fetch_token_t;
  fetch_token_t head_q, tail_q, bus_token, selected;
  logic [1:0] occupancy;
  logic fetch_accept, dequeue;

  // Conservative capacity: a full queue cannot replace a token on its
  // dequeue edge. No decode readiness feeds the fetch-PC enable.
  assign fetch_accept = occupancy < 2 && imem_ready && !reset && !redirect;
  assign dequeue = decode_accept && out.valid && !reset && !redirect;
  assign bus_token = {pc, imem_data, predict_taken};
  assign selected = occupancy != 0 ? head_q : bus_token;

  always_ff @(posedge clock) begin
    if (reset || redirect) begin
      // Occupancy invalidates both complete tokens. Payload flops retain
      // don't-care data, avoiding a correction/reset mux on every bit.
      occupancy <= 0;
    end else begin
      case (occupancy)
        0: if (fetch_accept && !dequeue) begin
          head_q <= bus_token;
          occupancy <= 1;
        end
        1: begin
          if (dequeue) begin
            if (fetch_accept) head_q <= bus_token;
            else occupancy <= 0;
          end else if (fetch_accept) begin
            tail_q <= bus_token;
            occupancy <= 2;
          end
        end
        2: if (dequeue) begin
          head_q <= tail_q;
          occupancy <= 1;
        end
        default: occupancy <= 0;
      endcase
    end
  end

  always_comb begin
    direct_branch = imem_data[6:0] == 7'b1100011 &&
                    (imem_data[14:12] == 3'd0 || imem_data[14:12] == 3'd1 ||
                     imem_data[14:12] == 3'd4 || imem_data[14:12] == 3'd5 ||
                     imem_data[14:12] == 3'd6 || imem_data[14:12] == 3'd7);
    direct_jump = imem_data[6:0] == 7'b1101111;
    direct_imm = direct_jump
               ? {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
                  imem_data[20], imem_data[30:21], 1'b0}
               : {{19{imem_data[31]}}, imem_data[31], imem_data[7],
                  imem_data[30:25], imem_data[11:8], 1'b0};
    // Check the full sum, including carry/negative high bits. Never wrap
    // a target into the one-megabyte executable region.
    direct_target = pc + direct_imm;
    predict_taken = (direct_jump || (direct_branch && counters[pc[7:2]][1]))
                    && pc[1:0] == 2'b00 && pc[31:20] == 12'b0
                    && direct_target[1:0] == 2'b00
                    && direct_target[31:20] == 12'b0;
    next_pc = predict_taken ? direct_target : pc + 32'd4;
  end

  // EX emits corrections only when it advances. They override even an
  // unready instruction bus; otherwise PC advances only on bus acceptance.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (fetch_accept) pc <= next_pc;
  end

  // Nonblocking updates intentionally give both the PC mux and ID/EX
  // the pre-edge lookup, including simultaneous same-index training.
  // Resolve against the current entry, never a snapshot from fetch.
  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 64; i++) counters[i] <= 2'b01;
    end else if (branch_train) begin
      if (branch_outcome) begin
        if (counters[branch_index] != 2'b11)
          counters[branch_index] <= counters[branch_index] + 2'b01;
      end else begin
        if (counters[branch_index] != 2'b00)
          counters[branch_index] <= counters[branch_index] - 2'b01;
      end
    end
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc    = selected.pc;
    out.instr = selected.instr;
    out.predicted_taken = selected.predicted_taken;
    // Availability and raw data are independent of correction. Correction
    // kills acceptance and ID/EX, never the decoder/dependency inputs.
    out.valid = occupancy != 0 || imem_ready;
  end

endmodule
