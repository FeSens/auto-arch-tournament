// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// Next-PC prediction: a PC-indexed BTB (64 entries, direct-mapped on
// pc[7:2], partial tag pc[13:8], partial target [19:2], 2-bit saturating
// hysteresis counter per entry; ctr == 0 is invalid). Taken branches, JAL
// and JALR (last target) train it.
// The lookup depends only on the pc flops (never on imem_data), so the
// instruction-bits -> decode -> pc path stays out of the fetch cone.
// Every prediction is verified in EX against the architectural next PC
// (ex_stage compares the pc register with the resolved next PC and
// registers the mismatch into EX/MEM.redir; the redirect is applied from
// MEM), so partial tags / targets / aliasing / false hits on non-control
// instructions only cost performance, never correctness.
//
// On flush (imem bus stall), the instruction emitted to ID is forced to
// NOP (`0x00000013` = ADDI x0,x0,0) with valid=0. Redirects do not
// touch this path; they flush the ID/EX register instead (see hazard_unit).
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage pc_next).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (load-use)
  input  logic              flush,            // emit NOP into ID this cycle
  input  logic              redirect,         // registered: MEM instr's fetch was wrong (PC mux only)
  input  logic [31:0]       redirect_target,  // registered: its architectural next PC
  // BTB training (registered, from the EX/MEM register)
  input  logic              btb_train_en,     // taken branch / JAL / JALR: write entry
  input  logic              btb_dec_en,       // not-taken branch: decrement matching entry
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]       btb_pc,           // pc of the training instruction
  input  logic [31:0]       btb_target,       // its taken target
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;
  localparam int unsigned BTB_N    = 64;

  logic [31:0] pc;
  logic [31:0] pc_plus4;
  logic [31:0] next_pc;

  // ── BTB storage (plain flops; only the counters are reset) ────────────
  // ctr == 0 means invalid, so tag/target need no reset. Predict when the
  // tag matches and ctr >= 2 (2-bit hysteresis).
  logic [BTB_N-1:0][1:0]  btb_ctr;
  logic [BTB_N-1:0][5:0]  btb_tag;
  logic [BTB_N-1:0][17:0] btb_tgt;

  // Lookup (pc flops -> 64:1 mux -> tag compare).
  logic        btb_hit;
  logic [17:0] btb_tgt_sel;
  logic [31:0] pred_pc;

  always_comb begin
    btb_tgt_sel = btb_tgt[pc[7:2]];
    btb_hit     = btb_ctr[pc[7:2]][1] && (btb_tag[pc[7:2]] == pc[13:8]);
    pred_pc     = {pc[31:20], btb_tgt_sel, 2'b00};
  end

  // Training (one instruction in EX/MEM, so the two enables are mutually
  // exclusive; an EX/MEM entry stays for exactly one cycle unless it is a
  // held dmem op, which never trains).
  //   taken branch / JAL / JALR: tag miss -> allocate (ctr = 2); tag match
  //                              -> saturating +1. Target is overwritten
  //                              (JALR last-target).
  //   not-taken branch         : tag match -> saturating -1.
  logic [5:0] btb_widx;
  assign btb_widx = btb_pc[7:2];

  for (genvar i = 0; i < BTB_N; i++) begin : g_btb
    logic sel;
    logic tag_eq;
    assign sel    = (btb_widx == 6'(i));
    assign tag_eq = (btb_tag[i] == btb_pc[13:8]);

    always_ff @(posedge clock) begin
      if (reset) begin
        btb_ctr[i] <= 2'b00;
      end else if (sel) begin
        if (btb_train_en) begin
          if (!tag_eq)                btb_ctr[i] <= 2'd2;
          else if (btb_ctr[i] != 2'd3) btb_ctr[i] <= btb_ctr[i] + 2'd1;
        end else if (btb_dec_en && tag_eq && btb_ctr[i] != 2'd0) begin
          btb_ctr[i] <= btb_ctr[i] - 2'd1;
        end
      end
      if (sel && btb_train_en) begin
        btb_tag[i] <= btb_pc[13:8];
        btb_tgt[i] <= btb_target[19:2];
      end
    end
  end

  always_comb begin
    pc_plus4 = pc + 32'd4;
    next_pc  = btb_hit ? pred_pc : pc_plus4;
  end

  // The late (MEM-stage, registered) redirect must override stall: the
  // redirecting instruction in MEM may coincide with imem_stall or a dmem
  // stall (a falsely-predicted load/store held in MEM) — without this
  // priority the redirect target would be dropped. Under a dmem stall the
  // redirect simply re-writes the same pc every held cycle.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (!stall)   pc <= next_pc;
  end

  assign imem_addr = pc;

  // `redirect` is deliberately NOT part of this mux: it would put it in
  // front of the regfile read address, decoder, imm_gen and the load-use
  // comparators. The wrong-path instruction that sits here during a
  // redirect cycle is killed by flush_id at the ID/EX register instead,
  // and the wrong-path instruction in EX is squashed by ex_stage (it sees
  // EX/MEM.redir), so MEM's redirect leaves no wrong-path survivor.
  always_comb begin
    out.pc       = pc;
    out.pc_plus4 = pc_plus4;
    out.instr    = flush ? 32'h0000_0013 : imem_data;
    out.valid    = !flush;
  end

endmodule
