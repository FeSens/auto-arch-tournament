// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + prediction + instr + valid) is *combinational* — no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// On flush or redirect, the instruction emitted to ID is forced to NOP
// (`0x00000013` = ADDI x0,x0,0). This prevents the hazard unit from
// observing a real rs1/rs2 from a wrong-path instruction and inserting
// a spurious load-use stall the cycle after a taken branch.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (load-use)
  input  logic              flush,            // emit NOP into ID this cycle
  input  logic              redirect,         // advancing EX prediction mismatch
  input  logic [31:0]       redirect_target,
  input  logic              resolve_valid,    // one pulse per EX advancement
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]       resolve_pc,       // [1:0] not part of the table key
  input  logic [31:0]       resolve_target,   // only legal aligned targets stored
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic              resolve_branch,
  input  logic              resolve_jump,
  input  logic              resolve_taken,
  input  logic              resolve_legal,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] predicted_next_pc;

  // 16 direct-mapped entries: 1 valid + 26 tag + 30 target + 2 counter
  // bits per entry (944 bits). Payloads need no reset: valid gates every
  // use. Lookup sees only registered state, with no EX-update bypass.
  // Fetch-only views of the scalar metadata registers below. Training
  // never selects metadata through the resolve index: each row's tag
  // comparison and counter next state use only that row's registers.
  logic [15:0] valid_view;
  logic [25:0] tag_view [0:15];
  logic [1:0] counter_view [0:15];
  logic [29:0] target_q [0:15];
  logic [3:0] fetch_index;
  logic [3:0] resolve_index;
  localparam logic [1:0] INVALIDATE = 2'b00;
  localparam logic [1:0] JUMP = 2'b01;
  localparam logic [1:0] TAKEN = 2'b10;
  localparam logic [1:0] NOT_TAKEN = 2'b11;
  logic [1:0] resolve_command;
  logic target_write;
  logic pending_target_valid_q;
  logic [3:0] pending_target_index_q;
  logic [29:0] pending_target_q;

  assign fetch_index = pc[5:2];
  assign resolve_index = resolve_pc[5:2];

  // Classify only the accepted event. Illegal/trapping controls must
  // invalidate a matching entry rather than allocate their target.
  always_comb begin
    resolve_command = INVALIDATE;
    if (resolve_legal) begin
      if (resolve_jump) resolve_command = JUMP;
      else if (resolve_branch)
        resolve_command = resolve_taken ? TAKEN : NOT_TAKEN;
    end
  end
  assign target_write = resolve_valid
                     && (resolve_command == JUMP || resolve_command == TAKEN);

  always_comb begin
    predicted_next_pc = pc + 32'd4;
    if (valid_view[fetch_index] && tag_view[fetch_index] == pc[31:6]
        && counter_view[fetch_index][1])
      predicted_next_pc = {target_q[fetch_index], 2'b00};
  end

  for (genvar row = 0; row < 16; row++) begin : metadata
    logic valid_q;
    logic [25:0] tag_q;
    logic [1:0] counter_q, counter_d;
    logic pending_valid_q;
    logic [25:0] pending_tag_q;
    logic [1:0] pending_command_q;
    logic row_enable, row_hit;

    assign valid_view[row] = valid_q;
    assign tag_view[row] = tag_q;
    assign counter_view[row] = counter_q;
    // Each independently enabled payload stays private to its row. Capture
    // no table state: the old event commits while the next is accepted,
    // even for consecutive aliases of this row. No maintenance forwarding
    // or indexed metadata read is needed.
    assign row_enable = resolve_valid && resolve_index == 4'(row);
    always_ff @(posedge clock) begin
      if (reset) begin
        pending_valid_q <= 1'b0;
      end else begin
        pending_valid_q <= row_enable;
        if (row_enable) begin
          pending_tag_q <= resolve_pc[31:6];
          pending_command_q <= resolve_command;
        end
      end
    end

    // Every commit input comes from this row's event and current state;
    // live EX feedback terminates at the capture registers above.
    assign row_hit = valid_q && tag_q == pending_tag_q;

    // Saturation selects next data, never a shared counter write enable.
    always_comb begin
      if (pending_command_q == JUMP)
        counter_d = 2'b11;
      else if (pending_command_q == TAKEN)
        counter_d = !row_hit ? 2'b10
                  : counter_q == 2'b11 ? 2'b11 : counter_q + 2'd1;
      else
        counter_d = counter_q == 2'b00 ? 2'b00 : counter_q - 2'd1;
    end

    always_ff @(posedge clock) begin
      if (reset) begin
        valid_q <= 1'b0;
      end else if (pending_valid_q) begin
        case (pending_command_q)
          INVALIDATE: begin
            // Recovering stale code must not evict a different PC's entry.
            if (row_hit) valid_q <= 1'b0;
          end
          JUMP, TAKEN: begin
            valid_q <= 1'b1;
            tag_q <= pending_tag_q;
            counter_q <= counter_d;
          end
          NOT_TAKEN: begin
            // Retain the target, and never allocate on a miss.
            if (row_hit) counter_q <= counter_d;
          end
          default: ;
        endcase
      end
    end
  end

  // Delay the single indexed target write to the same commit edge as its
  // metadata. Validity refreshes on EVERY edge regardless of any stall or
  // redirect, so an event commits once and reset cancels all pending work.
  // Event state totals 16*(1+26+2) + (1+4+30) = 499 source-level bits.
  always_ff @(posedge clock) begin
    if (reset) begin
      pending_target_valid_q <= 1'b0;
    end else begin
      pending_target_valid_q <= target_write;
      if (target_write) begin
        pending_target_index_q <= resolve_index;
        pending_target_q <= resolve_target[31:2];
      end
      if (pending_target_valid_q)
        target_q[pending_target_index_q] <= pending_target_q;
    end
  end

  // Recovery overrides instruction-bus backpressure. EX suppresses it
  // while a data-bus stall holds the resolving instruction. Ordinary
  // prediction advances only when ID accepts the current fetch.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (!stall && !flush) pc <= predicted_next_pc;
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc    = pc;
    out.predicted_next_pc = predicted_next_pc;
    out.instr = (flush || redirect) ? 32'h0000_0013 : imem_data;
    out.valid = !(flush || redirect);
  end

endmodule
