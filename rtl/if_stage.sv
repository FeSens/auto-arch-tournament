// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// On flush or EX redirect, the instruction emitted to ID is forced to NOP
// (`0x00000013` = ADDI x0,x0,0). This prevents the hazard unit from
// observing a real rs1/rs2 from a wrong-path instruction and inserting
// a spurious load-use stall after mispredict recovery.
//
// A decode-light static predictor recognizes legal B-type conditional
// branches with a negative immediate and predicts them taken, provided the
// predicted target is word-aligned. JAL/JALR remain unpredicted and resolve
// in EX.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (load-use)
  input  logic              flush,            // emit NOP into ID this cycle
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;
  localparam logic [31:0] NOP      = 32'h0000_0013;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [31:0] pc_plus4;
  logic [31:0] branch_imm;
  logic [31:0] predicted_target;
  logic        fetch_kill;
  logic        predict_enable;
  logic        branch_opcode;
  logic        branch_funct_legal;
  logic        predicted_taken;

  always_comb begin
    pc_plus4           = pc + 32'd4;
    branch_imm         = {{19{imem_data[31]}}, imem_data[31], imem_data[7],
                          imem_data[30:25], imem_data[11:8], 1'b0};
    predicted_target   = pc + branch_imm;
    fetch_kill         = reset || flush || redirect;
    predict_enable     = !fetch_kill && !stall;
    branch_opcode      = (imem_data[6:0] == 7'b1100011);
    branch_funct_legal = (imem_data[14:12] != 3'd2) && (imem_data[14:12] != 3'd3);
    predicted_taken    = predict_enable
                       && branch_opcode
                       && branch_funct_legal
                       && imem_data[31]
                       && (predicted_target[1:0] == 2'b00);

    next_pc = redirect        ? redirect_target :
              predicted_taken ? predicted_target :
                                pc_plus4;
  end

  // Redirect must override stall: a BRANCH/JAL/JALR in EX may fire
  // redirect on the same cycle as imem_stall or dmem_stall — without
  // this priority the redirect target would be silently dropped, the
  // PC would hold its old (wrong-path) value, and execution would
  // resume on the wrong path once the bus unstalls. Verified by the
  // VexRiscv-binary CoreMark sweep with --istall enabled.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (!stall)   pc <= next_pc;
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc               = pc;
    out.instr            = fetch_kill ? NOP : imem_data;
    out.predicted_taken  = predicted_taken;
    out.predicted_target = predicted_taken ? predicted_target : pc_plus4;
    out.valid            = !fetch_kill;
  end

endmodule
