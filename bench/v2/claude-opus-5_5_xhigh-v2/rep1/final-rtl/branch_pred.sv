// rtl/branch_pred.sv
//
// Decode-time (IF word) direction predictor.
//
//   JAL             : always predicted taken.
//   BRANCH (legal)  : agree-with-BTFN. A 128x2 counter table (distributed
//                     LUT-RAM, async read at pc[8:2]) says whether this
//                     branch disagrees with the static backward-taken /
//                     forward-not-taken guess:
//                       pred_taken = instr[31] ^ ctr[1]
//                     ctr = 0 at init, so the table starts out as BTFN.
//   anything else   : never predicted.
//
// A target with imm[1] = 1 traps when taken (no C extension), so such a
// JAL / branch is never predicted (tgt_ok); EX resolves it as before.
//
// The predicted target is ID's pc + imm (the shared imm_gen/adder), muxed
// into the PC in if_stage. Training is one sync write port driven only by
// EX/MEM flops: the counter read at predict time (carried down the pipe)
// steps toward 0 when the outcome agrees with BTFN and toward 3 when it
// disagrees. The write is idempotent, so a held EX/MEM is harmless.
//
// Latency:        prediction combinational; training write 1 cycle.
// RVFI fields:    none (only steers fetch; EX checks every prediction).
module branch_pred (
  input  logic        clock,
  // Fetch side (IF/ID combinational bundle).
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] instr,        // opcode, funct3, sign, imm[1] only
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [6:0]  idx,          // pc[8:2]
  input  logic        valid,
  output logic        pred,
  output logic [1:0]  ctr,
  // Training (EX/MEM flops).
  input  logic        train_en,     // valid conditional branch in EX/MEM
  input  logic [6:0]  train_idx,    // EX/MEM.pc[8:2]
  input  logic [1:0]  train_ctr,    // counter read at predict time
  input  logic        train_agree   // taken == instr[31] (BTFN was right)
);

  logic [1:0] tbl [0:127] /* synthesis syn_ramstyle = "distributed_ram" */;

  initial begin
    for (int i = 0; i < 128; i++) tbl[i] = 2'b00;
  end

  logic [1:0] ctr_new;
  always_comb begin
    if (train_agree) ctr_new = (train_ctr == 2'd0) ? 2'd0 : train_ctr - 2'd1;
    else             ctr_new = (train_ctr == 2'd3) ? 2'd3 : train_ctr + 2'd1;
  end

  always_ff @(posedge clock) begin
    if (train_en) tbl[train_idx] <= ctr_new;
  end

  logic is_jal;
  logic is_br;
  always_comb begin
    ctr    = tbl[idx];
    is_jal = (instr[6:0] == 7'b1101111);
    // Legal BRANCH: funct3 2/3 are reserved.
    is_br  = (instr[6:0] == 7'b1100011) && (instr[14:13] != 2'b01);
    // tgt_ok: J imm[1] = instr[21], B imm[1] = instr[8].
    pred   = valid && ((is_jal && !instr[21]) ||
                       (is_br  && !instr[8] && (instr[31] ^ ctr[1])));
  end

endmodule
