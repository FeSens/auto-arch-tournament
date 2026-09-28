// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + pred_taken + valid) is *combinational* — no separate IF/ID
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
  input  logic              redirect,         // qualified EX prediction recovery
  input  logic [31:0]       redirect_target,
  input  logic              branch_train_valid,
  input  logic [3:0]        branch_train_index,
  input  logic [5:0]        branch_train_tag,
  input  logic              branch_train_agree,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic        legal_branch, is_jal, raw_pred_taken;
  logic        agree_msb, branch_direction;
  logic [31:0] pred_imm, pred_target;

  branch_predictor u_predictor (
    .clock(clock), .reset(reset),
    .lookup_index(pc[5:2] ^ pc[10:7]), .lookup_tag(pc[11:6]),
    .agree_msb(agree_msb),
    .train_valid(branch_train_valid), .train_index(branch_train_index),
    .train_tag(branch_train_tag),
    .train_agree(branch_train_agree)
  );
  assign branch_direction = imem_data[31] ^ !agree_msb;

  // Predecode raw bus data, independently of flush/stall/recovery. Feeding
  // the flushed IF/ID instruction into this logic would couple prediction
  // back through the hazard unit. Conditional branches learn exceptions
  // to the cold backward-taken bias; JALR always resolves in EX.
  always_comb begin
    legal_branch = 1'b0;
    case (imem_data[14:12])
      3'd0, 3'd1, 3'd4, 3'd5, 3'd6, 3'd7:
        legal_branch = (imem_data[6:0] == 7'b1100011);
      default: ;
    endcase
    is_jal = (imem_data[6:0] == 7'b1101111);

    // With a word-aligned PC, target bit 1 is known from the immediate
    // before addition. No target comparison is on the eligibility path.
    raw_pred_taken = (pc[1:0] == 2'b00) &&
                     ((legal_branch && branch_direction && !imem_data[8]) ||
                      (is_jal && !imem_data[21]));
    pred_imm = is_jal
             ? {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
                imem_data[20], imem_data[30:21], 1'b0}
             : {{19{imem_data[31]}}, imem_data[31], imem_data[7],
                imem_data[30:25], imem_data[11:8], 1'b0};
    // One full-width B/J target adder, preserving modulo-32-bit arithmetic.
    pred_target = pc + pred_imm;
    next_pc = raw_pred_taken ? pred_target : pc + 32'd4;
  end

  // EX recovery overrides an imem stall, but EX suppresses recovery while
  // held by dmem/division. Ordinary prediction advances only on acceptance:
  // the predicting instruction itself must enter ID/EX on this edge.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (!stall && !flush) pc <= next_pc;
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc         = pc;
    out.instr      = (reset || flush || redirect) ? 32'h0000_0013 : imem_data;
    out.valid      = !(reset || flush || redirect);
    out.pred_taken = out.valid && raw_pred_taken;
  end

endmodule
