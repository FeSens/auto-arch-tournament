// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// Raw instruction bits never depend on EX recovery. Validity and the
// ID/EX register squash discard an unavailable or wrong-path fetch.
// Direct targets and pc+4 are added in parallel with a direction lookup;
// prediction selects completed addresses rather than an adder operand.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (load-use)
  input  logic              flush,            // invalidate this fetch
  input  logic              redirect,         // advancing EX prediction correction
  input  logic [31:0]       redirect_target,
  input  logic              branch_update,
  input  logic [6:0]        branch_index,
  input  logic              branch_taken,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [31:0] sequential_pc, direct_imm, direct_target;
  logic direct_branch, direct_jal, predicted_taken;
  logic [1:0] counters [0:127];

  always_comb begin
    direct_branch = imem_data[6:0] == 7'b1100011
                    && imem_data[14:12] != 3'd2
                    && imem_data[14:12] != 3'd3;
    direct_jal = imem_data[6:0] == 7'b1101111;
    direct_imm = direct_jal
               ? {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
                  imem_data[20], imem_data[30:21], 1'b0}
               : {{19{imem_data[31]}}, imem_data[31], imem_data[7],
                  imem_data[30:25], imem_data[11:8], 1'b0};
    sequential_pc = pc + 32'd4;
    direct_target = pc + direct_imm;
    predicted_taken = (direct_jal || (direct_branch && counters[pc[8:2]][1]))
                      && direct_target[1:0] == 2'b00;
    next_pc = predicted_taken ? direct_target : sequential_pc;
  end

  // A ready correction overrides younger fetch/interlock stalls. EX
  // defers correction while an older dmem request holds the pipeline.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (!stall)   pc <= next_pc;
  end

  // Train only on the single EX-to-EX/MEM acceptance event, using the
  // current counter for saturation, not the prediction saved with EX.
  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 128; i++) counters[i] <= 2'b01;
    end else if (branch_update) begin
      if (branch_taken && counters[branch_index] != 2'b11)
        counters[branch_index] <= counters[branch_index] + 2'd1;
      else if (!branch_taken && counters[branch_index] != 2'b00)
        counters[branch_index] <= counters[branch_index] - 2'd1;
    end
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc    = pc;
    out.instr = imem_data;
    out.predicted_taken = predicted_taken;
    out.direct_target = direct_target;
    out.valid = !flush;
  end

endmodule
