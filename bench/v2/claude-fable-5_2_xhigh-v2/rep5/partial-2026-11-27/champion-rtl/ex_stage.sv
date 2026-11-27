// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM
// only), runs the ALU / the sequential muldiv unit, resolves branches,
// computes the redirect target. Owns the EX/MEM pipeline register.
//
// Forwarding: the selects are fully precomputed in ID (id_ex_t fwd_*_ex
// bits: rd==rs match AND the producer's trap-gated reg_write), so the
// operand muxes are 2:1 and driven by ID/EX flops only. The producer two
// ahead (old MEM/WB forward) is bypassed into the ID/EX operand registers
// by ID at capture time, so there is no MEM/WB leg here.
// There are two mux pairs: the raw rs1/rs2 (branch compare, address
// adder, store data, muldiv, RVFI) and the ALU operands a/b, whose
// non-register alternatives (pc / 0 / imm) were pre-muxed in ID.
//
// Redirect: redir_c1 / redir_c0 / br_bad come from ID (target
// misalignment of JAL / branches is imm[1]; the fetch-cycle prediction
// is folded in, so a branch redirect is a mispredict); JALR is
// misaligned iff addr_sum[1]. redirect = jalr_go | (br_cond ? redir_c1 :
// redir_c0). It is RETIMED: its only sink is the flush_q register; the
// next cycle fetches flush_pc_q and squashes the wrong-path instruction
// that entered ID/EX (valid, reg_write, mem_read/write, is_illegal,
// muldiv start, ex_busy, its own redirect, PHT training).
//
// M-ops: `ex_busy` is high while an M-op waits for the muldiv unit. The
// hazard unit then holds PC and ID/EX; EX/MEM takes a bubble (unless a
// dmem stall holds it). The unit latches the post-forward operands on
// the first EX cycle; RVFI rs1/rs2 values of the M-op come from there.
//
// EX/MEM register: only valid and the side-effect ctrl bits are reset /
// bubbled; the data fields are clock-enable (= !stall) only.
//
// Latency:        1 cycle (EX/MEM register clocked here); M-ops 2 / 36.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  output ex_mem_t  out,
  output logic               ex_busy,
  // reg_write this instruction will carry into EX/MEM (trap-gated;
  // ignores ex_busy, during which ID/EX does not capture anyway).
  output logic               reg_write_next,
  // Registered redirect: set for exactly one cycle, the cycle AFTER a
  // mispredicted branch / an aligned JALR left EX. The instruction then
  // sitting in ID/EX is wrong-path and is squashed here; if_stage
  // fetches flush_pc_q in that same cycle. These two registers are the
  // only sinks of the late compare result besides the PHT `taken` flop.
  output logic               flush_q,
  output logic [29:0]        flush_pc_q,
  // PHT training, registered (one pulse per aligned branch leaving EX).
  output logic               bp_we,
  output logic [8:0]         bp_idx,
  output logic [1:0]         bp_old,
  output logic               bp_taken
);

  logic redirect;
  logic jalr_go;
  logic br_cond;

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;
  logic [31:0] alu_a;
  logic [31:0] alu_b;

  always_comb begin
    // 2:1, single flop select each. The value of the producer two ahead
    // was already written into the ID/EX operand registers by ID.
    rs1   = in.fwd_rs1_ex ? fwd_ex_mem : in.rs1_val;
    rs2   = in.fwd_rs2_ex ? fwd_ex_mem : in.rs2_val;
    alu_a = in.fwd_a_ex   ? fwd_ex_mem : in.op_a;
    alu_b = in.fwd_b_ex   ? fwd_ex_mem : in.op_b;
  end

  // ── Sequential M-extension unit ───────────────────────────────────────
  logic        md_done;
  logic [31:0] md_result;
  logic [31:0] md_a;
  logic [31:0] md_b;

  muldiv u_muldiv (
    .clock  (clock),
    .reset  (reset),
    .start  (in.is_muldiv && !flush_q),
    .accept (!stall),
    .op     (in.instr[14:12]),
    .a      (rs1),
    .b      (rs2),
    .done   (md_done),
    .result (md_result),
    .a_lat  (md_a),
    .b_lat  (md_b)
  );

  assign ex_busy = in.is_muldiv && !md_done && !flush_q;

  // ── ALU with flat result select ───────────────────────────────────────
  // JAL/JALR write the link value (pc+4, pre-gated in ID), M-ops the
  // muldiv result; both enter the ALU's AND-OR as `other`.
  logic [31:0] alu_other;
  logic [31:0] alu_result;
  assign alu_other = in.link | ({32{in.is_muldiv}} & md_result);

  alu u_alu (
    .sel_add    (in.sel_add),
    .sub        (in.alu_sub),
    .sel_slt    (in.sel_slt),
    .slt_signed (in.slt_signed),
    .logic_op   (in.logic_op),
    .sel_shl    (in.sel_shl),
    .sel_shr    (in.sel_shr),
    .sh_arith   (in.sh_arith),
    .a          (alu_a),
    .b          (alu_b),
    .other      (alu_other),
    .out        (alu_result)
  );

  // ── Dedicated data-address adder (LOAD/STORE address, JALR target) ────
  logic [31:0] addr_sum;
  assign addr_sum = rs1 + in.imm;

  // ── Branch resolve ────────────────────────────────────────────────────
  // One equality compare and one 33-bit less-than (bit 32 = sign for the
  // signed compares, 0 for the unsigned ones).
  logic cmp_eq;
  logic cmp_lt;
  logic jalr_bad;        // JALR with a misaligned target
  logic misalign_fault;  // late traps: JALR / taken branch to a bad target

  always_comb begin
    cmp_eq    = (rs1 == rs2);
    cmp_lt    = $signed({in.br_signed & rs1[31], rs1})
              < $signed({in.br_signed & rs2[31], rs2});
    br_cond   = in.br_use_eq ? cmp_eq : cmp_lt;

    // riscv-formal demands rvfi_trap=1 when next_pc is misaligned. The
    // offending instruction traps, does not redirect (PC stays linear)
    // and does not write rd. (A misaligned JAL already trapped in ID.)
    jalr_bad       = in.is_jalr && addr_sum[1];
    misalign_fault = jalr_bad || (in.br_bad && (br_cond ^ in.br_inv));
    jalr_go        = in.is_jalr && !addr_sum[1];
  end

  // redirect = mispredict (the prediction is folded into redir_c1/c0 in
  // ID) or an aligned JALR. Raw: it is qualified by !flush_q below.
  assign redirect       = jalr_go | (br_cond ? in.redir_c1 : in.redir_c0);
  assign reg_write_next = in.ctrl.reg_write && !jalr_bad && !flush_q;

  // Redirect target: JALR clears bit 0 (RV spec) and only redirects when
  // bit 1 is clear; branches use the alternate path registered in ID.
  logic [31:0] redirect_target;
  assign redirect_target = in.is_jalr ? {addr_sum[31:1], 1'b0} : in.btarget;

  // ── Registered redirect + PHT training ────────────────────────────────
  // flush_q is set in the cycle the redirecting instruction leaves EX
  // (!stall; a branch / JALR is never ex_busy). In the flush cycle EX/MEM
  // holds that instruction (no dmem op), so the cycle can never stall and
  // the squashed instruction is gone one cycle later.
  always_ff @(posedge clock) begin
    if (reset) begin
      flush_q <= 1'b0;
      bp_we   <= 1'b0;
    end else begin
      flush_q <= redirect && !flush_q && !stall;
      bp_we   <= in.bp_train && !flush_q && !stall;
    end
    flush_pc_q <= redirect_target[31:2];
    bp_idx     <= in.pc[10:2];
    bp_old     <= in.pht;
    bp_taken   <= br_cond ^ in.br_inv;
  end

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    // Control group. dmem stall holds; an M-op that is still computing
    // leaves a bubble. (M-ops have mem_read = mem_write = is_illegal = 0
    // and never fault, so only valid / reg_write need the ex_busy gate.)
    if (reset) begin
      reg_q.valid           <= 1'b0;
      reg_q.ctrl.reg_write  <= 1'b0;
      reg_q.ctrl.mem_read   <= 1'b0;
      reg_q.ctrl.mem_write  <= 1'b0;
      reg_q.ctrl.is_illegal <= 1'b0;
    end else if (!stall) begin
      // flush_q: the instruction in EX is wrong-path -> bubble.
      reg_q.valid           <= in.valid && !ex_busy && !flush_q;
      reg_q.ctrl.reg_write  <= in.ctrl.reg_write && !ex_busy && !jalr_bad
                               && !flush_q;
      reg_q.ctrl.mem_read   <= in.ctrl.mem_read  && !flush_q;
      reg_q.ctrl.mem_write  <= in.ctrl.mem_write && !flush_q;
      reg_q.ctrl.is_illegal <= (in.ctrl.is_illegal || misalign_fault)
                               && !flush_q;
    end

    // Data group: clock-enable only. Never cleared — forwarding from
    // EX/MEM is qualified by the (cleared) reg_write bit.
    if (!stall) begin
      reg_q.pc              <= in.pc;
      reg_q.alu_result      <= alu_result;
      reg_q.mem_addr        <= addr_sum;
      reg_q.write_data      <= rs2;
      reg_q.rd              <= in.rd;
      reg_q.rs1_addr        <= in.rs1_addr;
      reg_q.rs2_addr        <= in.rs2_addr;
      // M-ops: the forwarding sources have drained by the time the unit
      // is done, so report the operands it latched on its first cycle.
      reg_q.rs1_val         <= in.is_muldiv ? md_a : rs1;
      reg_q.rs2_val         <= in.is_muldiv ? md_b : rs2;
      // pc_next: the alternate path on a redirect, else the path fetch
      // followed (pc+4, or the predicted-taken / JAL target). A misalign
      // trap never redirects and was never followed, so it reports pc+4.
      reg_q.pc_next         <= redirect ? redirect_target : in.npc_pred;
      reg_q.ctrl.mem_width  <= in.ctrl.mem_width;
      reg_q.ctrl.mem_sext   <= in.ctrl.mem_sext;
      reg_q.ctrl.mem_to_reg <= in.ctrl.mem_to_reg;
      reg_q.instr           <= in.instr;
    end
  end

  assign out = reg_q;

endmodule
