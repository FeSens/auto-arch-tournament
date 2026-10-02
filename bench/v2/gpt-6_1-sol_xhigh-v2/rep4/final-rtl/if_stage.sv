// rtl/if_stage.sv
//
// Prediction-guided four-entry fetch queue. An empty queue falls through
// to the raw response; an occupied queue presents its registered head to
// every decode consumer. The bus PC advances on acquisition, independently
// of decode holds, using the prediction captured with that response.
//
// Recovery invalidates occupancy; direct recovery installs the resident PC
// and registered indirect recovery bypasses it for one landing cycle.
// Payload movement
// deliberately has no reset/recovery controls: speculative writes on those
// edges are unreachable after the independently flushed occupancy.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // decode cannot consume
  input  logic              imem_ready,       // raw fetch validity
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic              direct_redirect,  // install alternate direct PC
  input  logic [31:0]       redirect_target,
  input  logic              indirect_landing,
  input  logic [31:0]        indirect_target,
  input  logic             predicted_taken,
  input  logic [31:0]      predicted_target,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output logic              decode_ready,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] resident_pc_q, fetch_pc;
  logic [31:0] next_pc;
  logic [2:0] count_q;
  // Fixed packed banks avoid an unpacked array of structs in the formal
  // Verilog frontend and infer flip-flops rather than a target cache/RAM.
  logic [65:0] payload0_q, payload1_q, payload2_q, payload3_q;
  if_id_t response, head;
  logic storage_pop, storage_accept, storage_bypass, storage_enqueue;
  logic [2:0] append_index;

  assign storage_pop = (count_q != 3'd0) && !stall;
  assign storage_accept = imem_ready && ((count_q < 3'd4) || storage_pop);
  assign storage_bypass = (count_q == 3'd0) && !stall;
  assign storage_enqueue = storage_accept && !storage_bypass;
  assign append_index = count_q - (storage_pop ? 3'd1 : 3'd0);
  assign decode_ready = (count_q != 3'd0) || imem_ready;
  assign head = payload0_q;
  assign fetch_pc = indirect_landing ? indirect_target : resident_pc_q;

  always_comb begin
    next_pc = predicted_taken ? predicted_target : fetch_pc + 32'd4;
    response.predicted_taken = predicted_taken;
    response.pc = fetch_pc;
    response.instr = imem_data;
    response.valid = imem_ready;
    out = (count_q != 3'd0) ? head : response;
    out.valid = decode_ready;
  end

  // Append wins over shifting at its destination, including full pop/refill
  // and replacement of the sole entry. No reset or redirect enters these
  // enables or data selects; only PC/occupancy below accepts acquisitions.
  always_ff @(posedge clock) begin
    if (storage_pop) begin
      payload0_q <= payload1_q;
      payload1_q <= payload2_q;
      payload2_q <= payload3_q;
    end
    if (storage_enqueue) begin
      case (append_index)
        3'd0: payload0_q <= response;
        3'd1: payload1_q <= response;
        3'd2: payload2_q <= response;
        3'd3: payload3_q <= response;
        default: ;
      endcase
    end
  end

  // Only direct corrections enter the resident-PC mux. A JALR squash may
  // acquire speculatively here; its registered landing overrides the bus
  // next cycle. A ready landing advances to its own predicted successor;
  // an unaccepted landing commits its address before the bypass disappears.
  always_ff @(posedge clock) begin
    if (reset) begin
      resident_pc_q <= RESET_PC;
    end else if (direct_redirect) begin
      resident_pc_q <= redirect_target;
    end else begin
      if (storage_accept) resident_pc_q <= next_pc;
      else if (indirect_landing) resident_pc_q <= indirect_target;
    end
  end

  // Squash controls occupancy independently of packed payload writes.
  always_ff @(posedge clock) begin
    if (reset || redirect) begin
      count_q <= 3'd0;
    end else begin
      case ({storage_enqueue, storage_pop})
        2'b10: count_q <= count_q + 3'd1;
        2'b01: count_q <= count_q - 3'd1;
        default: ;
      endcase
    end
  end

  assign imem_addr = fetch_pc;

endmodule
