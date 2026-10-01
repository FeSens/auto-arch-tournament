// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// Decode always sees raw imem data. Recovery changes only PC selection
// and validity, never the instruction or source-index data paths.
// Direct transfers use exact immediate targets and one saved direction bit.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (load-use)
  input  logic              flush,            // invalidate fetch this cycle
  input  logic              redirect,         // EX prediction mismatch
  input  logic [31:0]       redirect_target,
  input  logic              train_valid,
  input  logic [5:0]        train_index,
  input  logic              train_agree,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [63:0] agreements;
  logic is_branch, is_jal, predicted_taken;
  logic [31:0] branch_imm, jump_imm, predicted_target;

  // Counters encode agreement with backward-taken/forward-not-taken bias.
  // Each entry owns its saturating transition. There is just one indexed
  // read (the fetch MSB), no training read mux or shared update datapath.
  for (genvar entry = 0; entry < 64; entry++) begin : agree
    logic [1:0] counter;
    assign agreements[entry] = counter[1];
    always_ff @(posedge clock) begin
      if (reset) counter <= 2'b10;
      else if (train_valid && train_index == 6'(entry)) begin
        if (train_agree) begin
          if (counter != 2'b11) counter <= counter + 2'b01;
        end else begin
          if (counter != 2'b00) counter <= counter - 2'b01;
        end
      end
    end
  end

  always_comb begin
    is_branch = imem_data[6:0] == 7'b1100011
                && (imem_data[14:12] == 3'd0 || imem_data[14:12] == 3'd1
                    || imem_data[14:12] == 3'd4 || imem_data[14:12] == 3'd5
                    || imem_data[14:12] == 3'd6 || imem_data[14:12] == 3'd7);
    is_jal = imem_data[6:0] == 7'b1101111;
    branch_imm = {{19{imem_data[31]}}, imem_data[31], imem_data[7],
                  imem_data[30:25], imem_data[11:8], 1'b0};
    jump_imm = {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
                imem_data[20], imem_data[30:21], 1'b0};
    predicted_target = pc + (is_jal ? jump_imm : branch_imm);
    predicted_taken = (is_jal || (is_branch && (agreements[pc[7:2]] == imem_data[31])))
                      && predicted_target[1:0] == 2'b00;
    next_pc = predicted_taken ? predicted_target : pc + 32'd4;
  end

  // Recovery overrides an instruction-bus stall or younger dependency.
  // EX suppresses recovery while an older dmem operation or DIV holds it.
  // Otherwise !stall accepts both this PC's instruction and its prediction.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (!stall)   pc <= next_pc;
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc    = pc;
    out.instr = imem_data;
    out.predicted_taken = predicted_taken;
    out.valid = !(flush || redirect);
  end

endmodule
