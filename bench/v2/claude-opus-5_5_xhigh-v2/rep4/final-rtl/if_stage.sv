// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid + prediction) is *combinational* — there is no
// separate IF/ID flop in this microarchitecture, the next-stage's ID/EX
// register captures everything one cycle later.
//
// Zero-bubble static/dynamic prediction: the fetched word is pre-decoded
// here (JAL / conditional branch detect, B/J immediate, pc+imm adder), so
// a predicted-taken transfer steers the PC on the very next edge with no
// tag or target storage. Direction for conditional branches comes from a
// 64 x 2-bit "agree" table (plain flops, indexed by pc[7:2]): counter
// MSB=1 means "agree with static BTFN" (backward taken / forward not
// taken, i.e. the imm sign bit instr[31]). Reset value 2'b10 makes the
// cold behaviour pure BTFN. The table is written from the EX/MEM
// register (bht_we/bht_widx/bht_wdata, computed in core.sv).
//
// A prediction is never made for a misaligned target, when imem did not
// deliver, or when the target would leave the 1 MiB memory window (the
// fetch word may be a wrong-path word after a mispredict/JALR). An
// un-predicted JAL is resolved in EX as before.
//
// The PC advances (with or without the prediction) exactly when ID/EX
// captures a valid instruction (!stall && !redirect), so pred_taken stays
// paired with the instruction entering ID/EX.
//
// On imem stall (flush), the instruction emitted to ID is forced to NOP
// (`0x00000013` = ADDI x0,x0,0) with valid=0. A redirect does NOT mux the
// payload: ID/EX is cleared by flush_id and the PC takes the redirect
// target over any stall.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (load-use / stalls)
  input  logic              flush,            // imem stall: NOP into ID
  input  logic              redirect,         // EX mispredict / JALR
  input  logic [31:0]       redirect_target,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  // BHT update port (driven from the EX/MEM register)
  input  logic              bht_we,
  input  logic [5:0]        bht_widx,
  input  logic [1:0]        bht_wdata,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;

  // ── Pre-decode of the fetched word ────────────────────────────────────
  logic        is_jal;
  logic        is_br;
  logic [19:0] imm_j;
  logic [19:0] imm_b;
  logic [19:0] tgt_j;
  logic [19:0] tgt_b;
  logic [1:0]  ctr;
  logic        dir;
  logic        pred_j;
  logic        pred_b;
  logic        pred_taken;

  logic [1:0]  bht [0:63];

  always_comb begin
    is_jal = (imem_data[6:0] == 7'b1101111);
    is_br  = (imem_data[6:0] == 7'b1100011) && (imem_data[14:13] != 2'b01);
    // Low 20 bits of the J / B immediates: pure wiring from the fetch
    // word, so each target adder starts with no imm-select LUT.
    imm_j  = {imem_data[19:12], imem_data[20], imem_data[30:21], 1'b0};
    imm_b  = {{8{imem_data[31]}}, imem_data[7],
              imem_data[30:25], imem_data[11:8], 1'b0};
    tgt_j  = pc[19:0] + imm_j;
    tgt_b  = pc[19:0] + imm_b;

    ctr = bht[pc[7:2]];
    dir = ctr[1] ? imem_data[31] : !imem_data[31];

    // imm[1] is instr[21] (J) / instr[8] (B): never predict a misaligned
    // target. The predicted target keeps only bits [19:0] (upper bits 0),
    // so wrong-path fetch stays inside [0, 1 MiB); EX redirects a
    // predicted-taken branch / JAL whose real target has upper bits set.
    // No select waits for a carry out.
    pred_j     = imem_ready && is_jal && !imem_data[21];
    pred_b     = imem_ready && is_br && dir && !imem_data[8];
    pred_taken = pred_j || pred_b;

    next_pc = pred_j ? {12'b0, tgt_j}
            : pred_b ? {12'b0, tgt_b}
                     : pc + 32'd4;
  end

  // ── BHT (64 x 2-bit agree counters, reset to weakly-agree) ───────────
  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 64; i++) bht[i] <= 2'b10;
    end else if (bht_we) begin
      bht[bht_widx] <= bht_wdata;
    end
  end

  // Redirect must override stall: a BRANCH/JALR in EX may fire redirect
  // on the same cycle as imem_stall or dmem_stall — without this priority
  // the redirect target would be silently dropped.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (!stall)   pc <= next_pc;
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc         = pc;
    out.instr      = flush ? 32'h0000_0013 : imem_data;
    out.valid      = !flush;
    out.pred_taken = pred_taken;
    out.pred_ctr   = ctr;
  end

endmodule
