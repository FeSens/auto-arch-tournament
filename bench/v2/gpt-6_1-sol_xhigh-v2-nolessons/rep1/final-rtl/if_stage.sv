// rtl/if_stage.sv
//
// Instruction fetch stage with two registered entries and empty bypass.
// The fetch PC advances on bus acceptance, independently of backend holds.
// Decode consumes the oldest word and its original fetch prediction.
//
// Raw instruction bits never depend on redirect. Availability travels
// separately; ID/EX validity kills discard unavailable or wrong-path words.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              decode_accept,    // valid head accepted by ID
  input  logic              imem_ready,       // fetched word is available
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  input  logic              train_valid,      // accepted legal nontrapping branch
  input  logic [5:0]        train_index,
  input  logic              train_taken,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output logic              head_valid,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [5:0] fetch_index;
  logic [63:0] counter_msb_q, counter_lsb_q;
  logic raw_branch, raw_jal, predicted_taken;
  logic [31:0] direct_imm, direct_target;
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
    logic        predicted_taken;
  } fetch_entry_t;
  fetch_entry_t head_q, tail_q, bus_entry;
  logic [1:0] count_q;
  logic fetch_accept;

  // A full queue can accept a replacement on the same edge as a dequeue.
  // Empty bypass advances fetch without saving a duplicate of the word.
  assign fetch_accept = imem_ready && (count_q != 2'd2 || decode_accept);
  assign head_valid = (count_q != 2'd0) || imem_ready;
  always_comb begin
    bus_entry.pc = pc;
    bus_entry.instr = imem_data;
    bus_entry.predicted_taken = predicted_taken;
  end

  assign fetch_index = pc[7:2] ^ pc[13:8];

  // Each entry updates from its own flops: no indexed training read mux
  // and no bypass into the fetch lookup. A same-edge lookup uses old state.
  for (genvar entry = 0; entry < 64; entry++) begin : g_counter
    always_ff @(posedge clock) begin
      if (reset) begin
        counter_msb_q[entry] <= 1'b1;  // weakly taken (10)
        counter_lsb_q[entry] <= 1'b0;
      end else if (train_valid && train_index == 6'(entry)) begin
        if (train_taken) begin
          counter_msb_q[entry] <= counter_msb_q[entry] | counter_lsb_q[entry];
          counter_lsb_q[entry] <= counter_msb_q[entry] | !counter_lsb_q[entry];
        end else begin
          counter_msb_q[entry] <= counter_msb_q[entry] & counter_lsb_q[entry];
          counter_lsb_q[entry] <= counter_msb_q[entry] & !counter_lsb_q[entry];
        end
      end
    end
  end

  // Raw direct-control predecode stays independent of recovery and the
  // full legality decoder. Reserved BRANCH funct3 and JALR never predict.
  always_comb begin
    raw_branch = imem_data[6:0] == 7'b1100011 &&
                 imem_data[14:12] != 3'd2 && imem_data[14:12] != 3'd3;
    raw_jal = imem_data[6:0] == 7'b1101111;
    direct_imm = raw_jal
      ? {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
         imem_data[20], imem_data[30:21], 1'b0}
      : {{19{imem_data[31]}}, imem_data[31], imem_data[7],
         imem_data[30:25], imem_data[11:8], 1'b0};
    direct_target = pc + direct_imm;
    predicted_taken = (raw_jal || (raw_branch && counter_msb_q[fetch_index]))
                      && direct_target[1:0] == 2'b00;
  end

  always_comb begin
    next_pc = predicted_taken ? direct_target : pc + 32'd4;
  end

  // Accepted recovery discards every younger word, even on a stalled bus
  // or a full queue. Payloads are retained on recovery; only occupancy is
  // cleared, so recovery never masks raw instruction bits into decode.
  always_ff @(posedge clock) begin
    if (reset) begin
      pc <= RESET_PC;
      count_q <= 2'd0;
      head_q <= '0;
      tail_q <= '0;
    end else if (redirect) begin
      pc <= redirect_target;
      count_q <= 2'd0;
    end else begin
      if (fetch_accept) pc <= next_pc;
      case (count_q)
        2'd0: if (fetch_accept && !decode_accept) begin
          head_q <= bus_entry;
          count_q <= 2'd1;
        end
        2'd1: begin
          case ({fetch_accept, decode_accept})
            2'b10: begin
              tail_q <= bus_entry;
              count_q <= 2'd2;
            end
            2'b01: count_q <= 2'd0;
            2'b11: head_q <= bus_entry;
            default: ;
          endcase
        end
        2'd2: if (decode_accept) begin
          head_q <= tail_q;
          if (fetch_accept) tail_q <= bus_entry;
          else count_q <= 2'd1;
        end
        default: count_q <= 2'd0;
      endcase
    end
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc    = (count_q == 2'd0) ? pc : head_q.pc;
    out.instr = (count_q == 2'd0) ? imem_data : head_q.instr;
    out.predicted_taken = (count_q == 2'd0) ? predicted_taken : head_q.predicted_taken;
    out.valid = head_valid;
  end

endmodule
