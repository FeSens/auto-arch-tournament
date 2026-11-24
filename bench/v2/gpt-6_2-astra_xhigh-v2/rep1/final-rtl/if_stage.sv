// A tagged word and its successor share a row. The registered normal PC
// and taken-recovery PC address the RAM in parallel with path selection.
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,
  input  logic              recover_target,
  input  logic              recover_fallthrough,
  input  logic              late_miss,
  input  logic [31:2]       late_next_pc,
  input  logic              taken,
  input  logic [31:2]       target,
  input  logic [31:0]       train_target,
  input  logic              train,
  input  logic              conditional,
  input  logic              eligible_jump,
  input  logic              counter_hit,
  input  logic [1:0]        old_counter,
  input  logic              fence_i,
  input  logic [31:2]       issue_pc,
  input  logic [19:2]       train_pc,
  input  logic [31:0]       issue_instr,
  input  logic [4:0]        producer_rd,
  input  logic              producer_lw,
  output logic              depends_on_rd,
  output logic              serializing,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  output if_id_t            out
);

  logic [31:2] normal_pc, target_q, fallthrough_q, late_pc_q;
  logic use_target, use_fallthrough, use_late;
  wire recovering = use_target || use_fallthrough || use_late;
  wire [31:2] pc_word = ({30{!recovering}} & normal_pc)
                      | ({30{use_target}} & target_q)
                      | ({30{use_fallthrough}} & fallthrough_q)
                      | ({30{use_late}} & late_pc_q);
  wire [31:2] next_word = pc_word + 1'b1;

  typedef struct packed {
    logic rs1, rs2, serial;
  } demand_t;

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic demand_t demand(input logic [31:0] w);
    demand_t d;
    d = '0;
    case (w[6:0])
      7'h03, 7'h23, 7'h67: d.rs1 = 1'b1;
      7'h13: d.rs1 = w[14:12] != 0;
      7'h33: begin
        d.rs1 = {w[31:25], w[14:12]} != 0;
        d.rs2 = d.rs1;
        d.serial = w[31:25] == 1 && w[14];
      end
      7'h63: begin
        d.rs1 = w[14];
        d.rs2 = w[14];
      end
      7'h0f: d.serial = w[14:12] == 1;
      default: ;
    endcase
    demand = d;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  typedef struct packed {
    logic [1:0]  counter;
    logic [19:2] target;
    demand_t     demand;
    logic        valid;
    logic [19:12] tag;
    logic [31:0] instr;
  } row_t;
  row_t normal_row;
  // Only the instruction and its tag are read on taken recovery.
  /* verilator lint_off UNUSEDSIGNAL */
  row_t target_row;
  /* verilator lint_on UNUSEDSIGNAL */

  logic clearing;
  logic [9:0] clear_index;
  logic [1:0] next_counter;

  // EX/MEM carries each instruction to a single in-order training port.
  // A deferred branch can supply its outcome here while younger work
  // stays speculative in EX.
  always_ff @(posedge clock) begin
    if (reset || fence_i) begin
      clearing <= 1'b1;
      clear_index <= '0;
    end else if (clearing) begin
      clearing <= !(&clear_index);
      clear_index <= clear_index + 1'b1;
    end
  end

  always_comb begin
    next_counter = 2'd0;
    if (train_target[31:20] == 0 && train_target[1:0] == 0) begin
      if (eligible_jump)
        next_counter = 2'd3;
      else if (conditional) begin
        if (!counter_hit)
          next_counter = taken ? 2'd2 : 2'd1;
        else if (taken)
          next_counter = old_counter == 3 ? 2'd3 : old_counter + 2'd1;
        else
          next_counter = old_counter == 0 ? 2'd0 : old_counter - 2'd1;
      end
    end
  end

  // Stripe the packed row across the narrow 1K-deep block RAMs. All
  // slices share addresses and a write enable, including invalidation.
  row_t write_row;
  assign write_row = {next_counter, train_target[19:2], demand(issue_instr), !clearing,
                      train_pc[19:12], issue_instr};
  wire write_enable = clearing || (train && !reset && !fence_i);
  wire [9:0] write_addr = clearing ? clear_index : train_pc[11:2];
  for (genvar offset = 0; offset < 64; offset += 16) begin : gen_ram
    localparam int WIDTH = 16;
    (* syn_ramstyle = "block_ram" *) logic [WIDTH-1:0] rows [0:1023];
    always_ff @(posedge clock)
      if (write_enable) rows[write_addr] <= write_row[offset +: WIDTH];
    assign normal_row[offset +: WIDTH] = rows[normal_pc[11:2]];
    assign target_row[offset +: WIDTH] = rows[target_q[11:2]];
  end

  logic normal_hit, target_hit, predict_taken;
  wire enabled = !clearing && !reset && !fence_i;
  assign normal_hit = enabled && !recovering && normal_pc[31:20] == 0
                   && normal_row.valid && normal_row.tag == normal_pc[19:12];
  assign target_hit = enabled && use_target && target_q[31:20] == 0
                   && target_row.valid && target_row.tag == target_q[19:12];
  assign predict_taken = normal_hit && normal_row.counter[1];

  // Hold a correction through imem waits and the edge releasing an older
  // dmem wait. ID also discards its fetch on that release edge.
  always_ff @(posedge clock) begin
    if (!recovering) begin
      target_q      <= target[31:2];
      fallthrough_q <= issue_pc + 1'b1;
    end
    if (!use_late) late_pc_q <= late_next_pc;
    if (reset) use_late <= 1'b0;
    else use_late <= late_miss || (stall && use_late);
    if (reset || late_miss) begin
      use_target      <= 1'b0;
      use_fallthrough <= 1'b0;
    end else begin
      use_target      <= recover_target      || (stall && use_target);
      use_fallthrough <= recover_fallthrough || (stall && use_fallthrough);
    end
    if (reset)       normal_pc <= '0;
    else if (!stall) normal_pc <= predict_taken ? {12'b0, normal_row.target} : next_word;
  end

  assign imem_addr = {pc_word, 2'b00};
  // Classify the live bus and both replay candidates alongside their tag
  // compares. Only operands needed in EX interlock the chosen instruction.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic depends(input logic [31:0] w, input demand_t d);
    // Loads are the only early-rs1 class with opcode bits [5:4] == 00.
    depends = (d.rs1 && w[19:15] == producer_rd && (|w[5:4] || !producer_lw)) ||
              (d.rs2 && w[24:20] == producer_rd);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  demand_t live_demand;
  assign live_demand = demand(imem_data);
  assign depends_on_rd = imem_ready ? depends(imem_data, live_demand) :
                         use_target ? depends(target_row.instr, target_row.demand) :
                                      depends(normal_row.instr, normal_row.demand);
  assign serializing = imem_ready ? live_demand.serial :
                       use_target ? target_row.demand.serial : normal_row.demand.serial;

  always_comb begin
    out.pc                   = imem_addr;
    out.fallthrough          = {next_word, 2'b00};
    out.prediction.hit       = normal_hit;
    out.prediction.counter   = normal_row.counter;
    out.prediction.target    = normal_row.target;
    out.prediction.same_word = !imem_ready || imem_data == normal_row.instr;
    out.instr = imem_ready ? imem_data : use_target ? target_row.instr : normal_row.instr;
    out.valid = imem_ready || normal_hit || target_hit;
  end
endmodule
