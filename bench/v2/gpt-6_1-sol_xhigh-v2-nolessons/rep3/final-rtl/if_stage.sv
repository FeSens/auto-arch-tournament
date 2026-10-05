// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// Decode always sees the raw bus payload, including during a redirect or
// an instruction-bus stall. Only validity marks an unavailable/killed
// fetch, keeping redirect control out of decode and regfile addressing.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (load-use)
  input  logic              flush,            // kill fetch validity only
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  input  logic              train_valid,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]       train_pc,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic              train_taken,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [31:0] sequential_pc, direct_imm, direct_target;
  logic [5:0] lookup_index, train_index;
  logic pre_branch, pre_jal, direct_aligned, predicted_taken;
  wire [63:0] counter_msb;
  wire [7:0] lookup_groups;
  logic direction;

  assign lookup_index = pc[7:2] ^ pc[13:8];
  assign train_index = train_pc[7:2] ^ train_pc[13:8];

  // Each entry owns its constant-index write enable and saturating state.
  // Lookup observes the old state on a simultaneous training edge.
  for (genvar e = 0; e < 64; e++) begin : gen_predictor
    localparam logic [5:0] INDEX = 6'(e);
    logic [1:0] counter_q;
    always_ff @(posedge clock) begin
      if (reset) counter_q <= 2'b01;
      else if (train_valid && train_index == INDEX) begin
        // Saturation is local next-state; each entry has one update enable.
        case (counter_q)
          2'b00: counter_q <= train_taken ? 2'b01 : 2'b00;
          2'b01: counter_q <= train_taken ? 2'b10 : 2'b00;
          2'b10: counter_q <= train_taken ? 2'b11 : 2'b01;
          default: counter_q <= train_taken ? 2'b11 : 2'b10;
        endcase
      end
    end
    assign counter_msb[e] = counter_q[1];
  end

  for (genvar g = 0; g < 8; g++) begin : gen_lookup
    assign lookup_groups[g] =
        ((lookup_index[2:0] == 3'd0) && counter_msb[g*8 + 0])
      | ((lookup_index[2:0] == 3'd1) && counter_msb[g*8 + 1])
      | ((lookup_index[2:0] == 3'd2) && counter_msb[g*8 + 2])
      | ((lookup_index[2:0] == 3'd3) && counter_msb[g*8 + 3])
      | ((lookup_index[2:0] == 3'd4) && counter_msb[g*8 + 4])
      | ((lookup_index[2:0] == 3'd5) && counter_msb[g*8 + 5])
      | ((lookup_index[2:0] == 3'd6) && counter_msb[g*8 + 6])
      | ((lookup_index[2:0] == 3'd7) && counter_msb[g*8 + 7]);
  end

  always_comb begin
    case (lookup_index[5:3])
      3'd0: direction = lookup_groups[0];
      3'd1: direction = lookup_groups[1];
      3'd2: direction = lookup_groups[2];
      3'd3: direction = lookup_groups[3];
      3'd4: direction = lookup_groups[4];
      3'd5: direction = lookup_groups[5];
      3'd6: direction = lookup_groups[6];
      default: direction = lookup_groups[7];
    endcase
    pre_branch = imem_data[6:0] == 7'b1100011 &&
                 imem_data[14:12] != 3'd2 && imem_data[14:12] != 3'd3;
    pre_jal = imem_data[6:0] == 7'b1101111;
    direct_imm = pre_jal
               ? {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
                  imem_data[20], imem_data[30:21], 1'b0}
               : {{19{imem_data[31]}}, imem_data[31], imem_data[7],
                  imem_data[30:25], imem_data[11:8], 1'b0};
    sequential_pc = pc + 32'd4;
    direct_target = pc + direct_imm;
    direct_aligned = direct_target[1:0] == 2'b00;
    predicted_taken = direct_aligned && (pre_jal || (pre_branch && direction));
    next_pc = predicted_taken ? direct_target : sequential_pc;
  end

  // Reset has highest priority, then the pending registered recovery.
  // A recovery must be consumed even when fetch is unavailable. Its
  // resolving EX/MEM entry is non-memory and cannot itself hold dmem.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (!stall)   pc <= next_pc;
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc    = pc;
    out.recovery_addr = predicted_taken ? sequential_pc : direct_target;
    out.predicted_taken = predicted_taken;
    out.direct_aligned = direct_aligned;
    out.instr = imem_data;
    out.valid = !(flush || redirect);
  end

endmodule
